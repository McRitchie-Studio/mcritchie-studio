# Slack Capture — connecting, reading, and categorizing a channel

## Status: Active

The standing procedure for turning a Slack channel into filed knowledge. It is
the fifth mouth of the funnel in
[`knowledge-capture.md`](knowledge-capture.md), which owns the intake protocol
this SOP hands off to; everything else needed to execute is inline here.

First run 2026-09-16 against a counterparty deal channel: several hundred
messages across eleven months, including thread replies, and it surfaced a
material fact that months of email had not. Which channel, and what it said,
stays in the private entity store — see **Boundaries**.

---

## Part 1 — Connect

### Create the app, not a "custom integration"

`<workspace>.slack.com/apps/manage/custom-integrations` is the WRONG door.
Slack deprecated custom integrations; their tokens cannot carry granular
scopes, and Slack's own banner on that page says to replace them with apps.

Go to **api.slack.com/apps → Create New App → From a manifest**. Not "AI agent"
and not "Starter app" — both scaffold an event-listening server this never uses.
Paste:

```json
{
  "display_information": {
    "name": "Knowledge Ingest",
    "description": "Read-only archive of Slack channel history into the knowledge layer.",
    "background_color": "#2c2d30"
  },
  "features": { "bot_user": { "display_name": "Knowledge Ingest", "always_online": false } },
  "oauth_config": {
    "scopes": {
      "bot": ["channels:history", "groups:history", "users:read", "channels:read", "groups:read"]
    }
  },
  "settings": {
    "org_deploy_enabled": false,
    "socket_mode_enabled": false,
    "token_rotation_enabled": false
  }
}
```

**Do not include `event_subscriptions: {}` or `interactivity: {}`.** Slack's
validator rejects an empty object on those keys — omitting them is how you turn
them off.

What each scope is actually for:

| Scope | Used by |
|---|---|
| `channels:history` **or** `groups:history` | the ingest — public or private; you need only the one matching the channel |
| `users:read` | the ingest, to name people — including Slack Connect guests, via `users.info` |
| `channels:read`, `groups:read` | **the id-discovery step below, and nothing else.** Drop them once you know the channel id |

`files:read` is not needed: file metadata rides the message payload.

Every scope is read-only. Nothing holding this token can post, edit, or delete,
which is the property that makes the credential safe to leave in an
agent-readable vault.

### Bot token or user token

| | Bot (`xoxb-`) | User (`xoxp-`) |
|---|---|---|
| Reaches a channel by | being invited to it | the authorizing user being in it |
| Visible to others | **yes** — the app appears as a member | no |
| Blast radius | only invited channels | everything that user can see |
| Right for | a standing feed | a one-off pull |

The manifest above requests **bot** scopes only. For a user token, add the same
list under a `"user"` key and install again.

On a **Slack Connect** channel the invite is visible to the external
organization. Give the counterparty a heads-up before inviting; a bot appearing
unannounced in a live deal channel is a conversation you want to have chosen.

If you file a **user** token, treat it as an admin-lane credential — its reach
is the whole workspace, which is a different risk than the bot's.

### File the token

**Vault `studio-agents`, item `slack.studio.agents`, category API_CREDENTIAL,
field `credential`.** The consuming constant is `Slack::Credentials::ITEM` in
`mcritchie-industries`. Vault roles and who can read which:
[`credential-inventory.md`](credential-inventory.md).

**Do not file it in `studio-agents-admin`.** The reason is mechanical, not
philosophical: the ingest calls a bare `op read` with whatever token the shell
already carries, which in every agent lane is `OP_SERVICE_ACCOUNT_TOKEN`. An
admin-vault item is simply not readable with that token. **And the failure is
silent** — `shell_read_from_op` rescues to nil, `configured?` returns false, and
`bin/rails slack:pull` prints `No Slack token` and **exits 0**. The lane looks
idle rather than broken.

The agent service account **cannot create or edit 1Password items** (measured —
`(101) You do not have permission`, for creates as well as deletes, despite an
unspent write quota). Steffon prepares the item under the admin writing lane per
[`credential-filing`](../agents/steffon/sops/credential-filing.md); the operator
pastes the secret.

Leave the field **empty** until the real token exists. A placeholder makes
`configured?` return true and sends the job at Slack for an `invalid_auth`,
dressing "not filled in yet" as a broken credential.

### Invite the bot, then find the channel id

```
/invite @Knowledge Ingest
```

Do not go hunting for the channel id in the UI — ask Slack. The token is piped
into curl's config on stdin so it never appears in `ps`, a shell variable, or
your history:

```bash
slack_curl() {                 # usage: slack_curl <api-method> [query...]
  local method="$1"; shift
  op read "op://studio-agents/slack.studio.agents/credential" \
    | sed 's|^|header = "Authorization: Bearer |; s|$|"|' \
    | curl -sS --config - --get "https://slack.com/api/${method}" "$@"
}

# prove the token before pulling anything
slack_curl auth.test | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d if d.get("ok") else "FAILED: "+d.get("error",""))'

# every page of the channel list, not just the first 200
cursor=""
while :; do
  page=$(slack_curl conversations.list \
           -d types=public_channel,private_channel -d limit=200 \
           -d exclude_archived=true -d "cursor=${cursor}")
  echo "$page" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if not d.get("ok"):
    sys.exit("Slack said: " + d.get("error","unknown_error"))
for c in d["channels"]:
    print(c["id"], c["name"], "member" if c.get("is_member") else "NOT A MEMBER")
print("CURSOR=" + (d.get("response_metadata") or {}).get("next_cursor",""), file=sys.stderr)'
  cursor=$(echo "$page" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("response_metadata") or {}).get("next_cursor",""))')
  [ -z "$cursor" ] && break
done
```

`NOT A MEMBER` means `conversations.history` will answer `not_in_channel`. Fix
the invite before blaming the token. Any `ok: false` prints Slack's own error
slug — `invalid_auth`, `missing_scope`, `not_in_channel` each name their fix.

---

## Part 2 — Read

Add the channel to `mcritchie-industries/config/slack_channels.yml` — `id`,
`name`, `entity`, `path`, `category`, and the per-agent `access` map — then:

```bash
cd /Users/alex/projects/mcritchie-industries
bin/rails slack:pull                  # every configured channel
bin/rails "slack:pull[channel-name]"  # one, by name or id
SLACK_PULL_SINCE=0 bin/rails slack:pull   # full rebuild, ignore the cursor
```

`SLACK_BOT_TOKEN` in the environment overrides the 1Password read, which is how
a Heroku dyno or CI runs it without `op`.

**The pull is manual. There is no scheduler.** Run it yourself, or wire it up
separately.

What lands: **one JSON archive per channel per calendar month**, at a stable S3
key, with one `Studio::KnowledgeDoc` per month pointing at it, `status: inbox`.

Five properties worth knowing before you trust the output:

- **Each run re-reads `LOOKBACK_SECONDS` behind its cursor** (14 days). Slack
  returns a thread parent in `conversations.history` only when the parent is
  new, so a cursor sitting past the parent would never see later replies to it.
  The overlap is deliberate and free — the merge is keyed on `ts`.
  **Known bound:** a reply to a thread whose parent is older than the window is
  not picked up; `SLACK_PULL_SINCE=0` rebuilds the channel and repairs it.
- **The cursor counts top-level messages only.** A reply carries a later `ts`
  than the message it answers, so counting replies would push the cursor past
  top-level messages posted beside them.
- **Thread replies are fetched separately**, through `conversations.replies`.
  They never appear in `conversations.history`.
- **Slack Connect guests resolve through `users.info`.** `users.list` returns
  your own workspace only, so the counterparty's people are absent from it —
  most of the value on exactly the channels this exists for. Misses are cached
  per run.
- **A failed channel exits non-zero** and writes an `ErrorLog`. Its siblings
  still run; a partial pull is worth keeping.

The task reports `fetched N messages + M thread replies, K new`. On a quiet
channel `K` is 0, no month is rewritten, and no document row is touched.

---

## Part 3 — Categorize

Run the intake protocol from [`knowledge-capture.md`](knowledge-capture.md) over
each pulled month. Slack differs from the email and file-drop mouths in four
ways:

**1. Read a month as a unit, not a message at a time.** A Slack month is one
document. The meaning is in the thread, and a line like *"updated the sheet to
show the revised figure"* is inert until read against the document it describes.

**2. Cross-reference hard — this is where Slack earns its keep.** Chat records
decisions that never reach a document, and one line of it can settle a question
the signed paperwork left open — a counterparty explaining in passing why a
number moved, months before anyone asks. Reconcile every figure against what is
already filed and send contradictions to the discrepancy record. **Keep the
quotes themselves in the entity's private store**, never in this repo.

**3. Access defaults to the deal side.** `samson: full`, `dawn: none` unless
there is a reason otherwise. A channel shared with an external organization
carries their commercial positions; promoting later is one edit.

**4. Everything in it is a claim.** These are statements by counterparties,
advisors and brokers, captured verbatim — excellent evidence of *what was said
and when*, which is what settles a "we agreed to X" dispute, and not filed
facts. The ingest writes that line into `source_note`; keep it through triage.

### Filing a month

Classification is written once, at create. **A later pull refreshes `byte_size`
and nothing else**, so these edits survive the next run:

```bash
cd /Users/alex/projects/mcritchie-industries
bin/rails runner '
  doc = Studio::KnowledgeDoc.find_by(s3_key: "knowledge/<entity>/<path>/<channel>-<YYYY-MM>.json")
  doc.update!(
    access: { "samson" => "full", "dawn" => "aware" },   # per-agent, aware needs a safe summary
    summary: "One safe sentence plus the boundary line, for aware-level agents.",
    source_note: doc.source_note + " Triaged <date>: <what this month holds, what it contradicts>.",
    expectation_id: <id>,                                 # link the expectation it satisfies
    status: "filed"
  )
  puts doc.reload.slice(:id, :status, :access, :expectation_id)
'
```

Leave a month `inbox` if you have not read it. `filed` is a claim that someone
did.

---

## Boundaries

- Confidential by default: private buckets, presigned links, **never an
  artifact**, never a public store. This repo is public — channel names,
  external user ids and counterparty quotes are placeheld here on purpose.
- Read-only, always. No scope in this SOP lets an agent speak in a channel, and
  none should be added without the operator's explicit decision.
- Capture never merges, deploys, or touches the release ladder.
- A channel shared with an external organization is **their** correspondence
  too. Pull it for the record, not to mine the counterparty; what you learn goes
  to the deal file, not into a negotiating posture you would not defend openly.
