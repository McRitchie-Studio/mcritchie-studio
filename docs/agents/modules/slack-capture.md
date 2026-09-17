# Slack Capture — connecting, reading, and categorizing a channel

## Status: Active

The standing procedure for turning a Slack channel into filed knowledge. It is
the fourth mouth of the funnel in
[`knowledge-capture.md`](knowledge-capture.md), which owns the intake protocol
this SOP hands off to; everything else needed to execute is inline here.

First run 2026-09-16 against a counterparty deal channel: several hundred
messages across eleven months, including thread replies, and it surfaced a
material fact that months of email had not. Which channel, and what it said,
stays in the private entity store — see **Boundaries**.

---

## Part 1 — Connect

### Create the app, not a "custom integration"

`mcritchie.slack.com/apps/manage/custom-integrations` is the WRONG door. Slack
deprecated custom integrations; their tokens cannot carry granular scopes, and
Slack's own banner on that page says to replace them with apps.

Go to **api.slack.com/apps → Create New App → From a manifest**. Not "AI agent"
and not "Starter app" — both scaffold an event-listening server this never uses.
Paste:

```json
{
  "display_information": {
    "name": "McRitchie Knowledge Ingest",
    "description": "Read-only archive of Slack channel history into the McRitchie knowledge layer.",
    "background_color": "#2c2d30"
  },
  "features": { "bot_user": { "display_name": "Knowledge Ingest", "always_online": false } },
  "oauth_config": {
    "scopes": {
      "bot":  ["channels:history","channels:read","groups:history","groups:read","users:read","files:read"],
      "user": ["channels:history","channels:read","groups:history","groups:read","users:read","files:read"]
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

Every scope is read-only. Nothing holding this token can post, edit, or delete,
which is the property that makes the credential safe to leave in an
agent-readable vault.

### Bot token or user token

The manifest asks for both, so one install yields both and the choice can be
deferred.

| | Bot (`xoxb-`) | User (`xoxp-`) |
|---|---|---|
| Reaches a channel by | being invited to it | the authorizing user being in it |
| Visible to others | **yes** — the app appears as a member | no |
| Blast radius | only invited channels | everything that user can see |
| Right for | a standing feed | a one-off pull |

On a **Slack Connect** channel the invite is visible to the external
organisation. Give the counterparty a heads-up before inviting; a bot appearing
unannounced in a live deal channel is a conversation you want to have chosen.

If you file a **user** token, treat it as an admin-lane credential — its reach
is the whole workspace, which is a different risk than the bot's.

### File the token

**Vault `studio-agents`, item `slack.studio.agents`, category API_CREDENTIAL,
field `credential`.** The consuming constant is
`Slack::Credentials::ITEM` in `mcritchie-industries`.

**Do not file it in `studio-agents-admin`.** Measured 2026-09-16: the agent
service account can read exactly four vaults — `Commercial Welding`,
`family-agents`, `industries-agents`, `studio-agents` — and the admin vault is
not among them. The admin lane is reachable only with
`OP_ADMIN_SERVICE_ACCOUNT_TOKEN` from `~/.zprofile.admin`, which is stripped
from agent shells at spawn. **The failure is silent**: `op read` fails, the
credentials class rescues to nil, and the ingest reports "unconfigured" rather
than "refused" — so the lane looks idle instead of broken.

The agent service account **cannot create or edit 1Password items** (measured —
`(101) You do not have permission`, for creates as well as deletes, despite an
unspent write quota). Steffon prepares the item under the admin writing lane per
[`credential-filing`](../agents/steffon/sops/credential-filing.md); Mr.
McRitchie pastes the secret.

Leave the field **empty** until the real token exists. A placeholder makes
`configured?` return true and sends the job at Slack for an `invalid_auth`,
dressing "not filled in yet" as a broken credential.

### Invite the bot, then find the channel id

```
/invite @Knowledge Ingest
```

Do not go hunting for the channel id in the UI — ask Slack:

```bash
V=$(op read "op://studio-agents/slack.studio.agents/credential")
curl -sS -H "Authorization: Bearer $V" \
  "https://slack.com/api/conversations.list?types=public_channel,private_channel&limit=200&exclude_archived=true" \
  | python3 -c 'import json,sys; [print(c["id"], c["name"], "member" if c.get("is_member") else "NOT A MEMBER") for c in json.load(sys.stdin)["channels"]]'
```

`NOT A MEMBER` means `conversations.history` will answer `not_in_channel`. Fix
the invite before blaming the token.

Prove the whole path before pulling anything:

```bash
curl -sS -H "Authorization: Bearer $V" https://slack.com/api/auth.test
```

---

## Part 2 — Read

Add the channel to `mcritchie-industries/config/slack_channels.yml`, then:

```bash
cd /Users/alex/projects/mcritchie-industries
bin/rails slack:pull                          # every configured channel
bin/rails "slack:pull[channel-name]"           # one
```

What lands: **one JSON archive per channel per calendar month**, at a stable S3
key, with one `Studio::KnowledgeDoc` per month pointing at it. Re-running
resumes from the newest stored `ts` and merges — an ongoing feed costs nothing
after the first backfill.

Three properties worth knowing before you trust the output:

- **Thread replies are fetched separately.** They never appear in
  `conversations.history`, which is how a busy channel can look empty.
- **Documents land as `status: inbox`, never `filed`.** Filing is Part 3.
- **`users.list` misses Slack Connect externals.** The counterparty's people come
  back as raw ids (`U0XXXXXXXXX`) because they are not in your workspace
  directory. `users.info` resolves them. Until the ingest does that fallback,
  resolve the ids by hand before filing — an archive whose main speakers are hex
  strings is an archive nobody will read.

---

## Part 3 — Categorize

Run the intake protocol from
[`knowledge-capture.md`](knowledge-capture.md) over each pulled month. Slack
differs from the email and file-drop mouths in four ways:

**1. Read a month as a unit, not a message at a time.** A Slack month is one
document. The meaning is in the thread, and a line like *"updated the sheet to
show the revised figure"* is inert until read against the document it describes.

**2. Cross-reference hard — this is where Slack earns its keep.** Chat records
decisions that never reach a document, and one line of it can settle a question
that the signed paperwork left open — a counterparty explaining in passing why a
number moved, months before anyone asks. Reconcile every figure against what is
already filed and send contradictions to the discrepancy record. **Keep the
quotes themselves in the entity's private store**, never in this repo.

**3. Access defaults to the deal side.** Set `samson: full`, `dawn: none`
unless there is a reason otherwise. A channel shared with an external
organisation carries their commercial positions; promoting later is one edit.

**4. Everything in it is a claim.** These are statements by counterparties,
advisors and brokers, captured verbatim. They are excellent evidence of *what
was said and when* — which is exactly what settles a "we agreed to X" dispute —
and they are not filed facts. Say so in `source_note`; the ingest writes that
line automatically and it should survive triage.

Stamp each month `filed` when triage is done, and link the expectation it
satisfies.

---

## Boundaries

- Confidential by default: private buckets, presigned links, **never an
  artifact**, never a public store.
- Read-only, always. No scope in this SOP lets an agent speak in a channel, and
  none should be added without Mr. McRitchie's explicit decision.
- Capture never merges, deploys, or touches the release ladder.
- A channel shared with an external organisation is **their** correspondence
  too. Pull it for the record, not to mine the counterparty; what you learn goes
  to the deal file, not into a negotiating posture you would not defend openly.
