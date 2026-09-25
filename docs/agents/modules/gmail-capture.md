# Gmail Capture — reading one mailbox into the funnel, read-only

## Status: Active

The standing procedure for turning mail that arrives in Alex's own
mailbox into filed knowledge, without him forwarding each message by hand. It
is the sixth mouth of the funnel in
[`knowledge-capture.md`](knowledge-capture.md), which owns the intake protocol
this SOP hands off to; everything else needed to execute is inline here.

It feeds the EXISTING desk queue — the same `DeskCaptureItem` rows, the same
`/admin/desk` page, the same sweep — so nothing downstream has a second code
path to learn.

Designed and approved 2026-09-17. Alex chose the narrowest of the
three identities on offer and declined the draft capability; **Decisions** below
records what was rejected and why, because that is the part a later session is
most likely to undo by accident.

---

## What this does NOT do

Read this section first. It is the whole reason the credential is safe to file
in an agent-readable vault.

| It cannot | Because |
|---|---|
| Send, reply, or forward | The grant is one scope, `gmail.readonly`. Sending needs `gmail.send`, `gmail.compose`, `gmail.modify` or `mail.google.com` — none is requested, and `Gmail::Client::SCOPES` is a frozen one-entry array the suite asserts |
| Create or edit drafts | Same. **There is no draft-only Gmail scope** — `gmail.compose` covers drafts AND send, so "can draft, can never send" could only ever be a property of our code. Alex declined that trade for this reader. Drafting lives in the separate Workspace service-account lane — see `workspace:draft` in [`workspace-provision`](../agents/steffon/sops/workspace-provision.md) |
| Archive, label, star, or mark read | Needs `gmail.modify`, which also permits send. The ingest deliberately leaves the mailbox untouched and tracks its position in OUR database (`desk_capture_items.history_id`) |
| Delete anything | Needs `gmail.modify` (trash) or `mail.google.com` (permanent). Neither is requested |
| Read mail outside the configured query | `GMAIL_CAPTURE_QUERY` goes into `messages.list` as `q`, so a non-matching message is **never downloaded**. There is no post-filter to get wrong. A blank query REFUSES rather than defaulting to the whole mailbox |
| Read any OTHER mailbox | The credential is a refresh token for one user. This is the reason a service account with domain-wide delegation was rejected — see **Decisions** |

`Gmail::Client` has no method that writes. Not a disabled one, not a guarded
one — every Gmail call in the class funnels through a private `#get` that builds
a `Net::HTTP::Get`. The one POST in the file is addressed to Google's token
endpoint, never to the Gmail API, and the suite asserts that split.

---

## Part 1 — Connect

### Create the OAuth client — user type INTERNAL, client type Web application

Google Cloud Console → **APIs & Services → Credentials → Create credentials →
OAuth client ID**, in the project that already holds the hub's SSO client.

- **User type: Internal.** Not optional in practice. An **External** app in
  "Testing" status is issued refresh tokens that **expire after 7 days**, which
  would kill this lane weekly; and an External app requesting a restricted
  scope needs a third-party security assessment. Internal is exempt from the
  unverified-app screen and the 100-user cap. Confirm the scope is accepted
  without a verification prompt while you are in the console.
- **Application type: Web application.**
- **Authorized redirect URI:** `http://localhost:8767/oauth2/callback`. Google
  exempts localhost URIs from its HTTPS rule, which is why a credential minted
  once needs no public callback and no hub route.
- **Scope:** `https://www.googleapis.com/auth/gmail.readonly`, and nothing else.

**Do not reuse the existing `Google | McRitchie Studio` client.** That is the
hub's and Turf Monster's SSO client. Adding a restricted Gmail scope to it puts
that scope on the consent screen every sign-in passes through, and ties the
Gmail credential to the app's login secret so rotating one forces the other.

### Mint the refresh token

Once, at Alex's desk, signed in as the mailbox owner:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/gmail-oauth-mint --client-id <id> --client-secret <secret>
```

It prints the consent URL, catches the redirect on the loopback port, exchanges
the code, and prints the JSON object to paste. It stores nothing. `access_type=offline`
plus `prompt=consent` is what yields a refresh token at all — without both,
Google returns an access token only and the script aborts saying so.

### File the credential

**Vault `studio-agents`, item `gmail.studio.agents`, category API_CREDENTIAL,
ONE field `credential`** holding the whole object:

```json
{ "client_id": "…", "client_secret": "…", "refresh_token": "1//…" }
```

One field, not three, because `op read` is one call per field path and the
service account's daily quota is account-wide and shared by every lane. The
consuming constant is `Gmail::Credentials::ITEM`.

**Do not file it in `studio-agents-admin`.** The reason is mechanical: the
ingest calls a bare `op read` with whatever token the shell already carries,
which in every agent lane is `OP_SERVICE_ACCOUNT_TOKEN`, and an admin-vault item
is simply not readable with it — **silently**. Vault roles and who can read
which: [`credential-inventory.md`](credential-inventory.md).

The agent service account **cannot create or edit 1Password items**. Steffon
prepares the item under the admin writing lane per
[`credential-filing`](../agents/steffon/sops/credential-filing.md);
Alex pastes the secret.

Leave the field **empty** until the real values exist. This lane distinguishes
the two states on purpose — empty reads as "not configured yet" and skips
politely, while a value that exists and cannot be parsed **raises**:

| Field holds | `configured?` | `gmail:pull` |
|---|---|---|
| nothing | false | prints the skip, exits 0 (or 1 under `GMAIL_PULL_STRICT`) |
| the bare refresh token | true | **fails loudly** — "must hold a JSON object with client_id, client_secret, refresh_token" |
| malformed JSON | true | **fails loudly** — "is not valid JSON" |
| the real object | true | pulls |

### Prove it before pulling anything

```bash
cd /Users/alex/projects/mcritchie-studio
bin/rails gmail:check
```

It names the mailbox the credential actually opened, the scopes, the recorded
cursor and the configured query — and reads nothing else. A wrong mailbox or an
unset query is visible here rather than after a pull.

### Set the query — in config, never in this repo

```bash
heroku config:set -a mcritchie-studio \
  GMAIL_CAPTURE_QUERY='from:(a@example.com OR b@example.com) OR subject:"deal name"'
```

**mcritchie-studio is PUBLIC.** The deal cast is third-party names, so it must
never be a committed YAML the way `slack_channels.yml` can be in the private
entity repo. A config value also means widening the cast is an operator edit
rather than a deploy. Optional: `GMAIL_CAPTURE_BACKFILL_DAYS` (default 90)
bounds the first run and any cursor recovery.

---

## Part 2 — Read

```bash
cd /Users/alex/projects/mcritchie-studio
bin/rails gmail:pull
```

**The pull is manual. There is no scheduler.** Run it yourself, or wire it up
separately. `GMAIL_OAUTH_CREDENTIAL` in the environment overrides the 1Password
read, which is how a Heroku dyno or CI runs it without `op`.

What lands: one raw `.eml` per matching message in the private
`mcritchie-studio-desk` bucket under `gmail/<message-id>.eml`, and one
`DeskCaptureItem` per `.eml` with `source: "gmail"`, `status: "received"`,
queued on `/admin/desk` for the intake protocol.

Six properties worth knowing before you trust the output:

- **Only matches are ever fetched.** The query rides in the request. On the
  incremental path Gmail's history reports *every* change in the mailbox —
  including personal mail — so those ids are **intersected with a query-scoped
  list** rather than trusted; an id outside the query is never requested.
- **The cursor is the max `history_id` we durably recorded**, not a separately
  stored high-water mark. A pull that crashes after fetching but before saving
  leaves it untouched, so the next run re-reads that window instead of stepping
  over it. It resumes AT the cursor, so the last message is re-offered and the
  `s3_key` check absorbs it.
- **An expired cursor self-heals.** Gmail keeps history for a limited window —
  typically about a week, occasionally hours. A 404 there is an *expected* path:
  the pull falls back to a date-bounded full sync and says so in its output.
- **A blank query refuses.** The failure mode of a missing config is "pulled
  nothing", never "pulled everything".
- **A revoked credential fails LOUD** — non-zero exit plus an `ErrorLog`, never
  the `slack:pull`-style quiet exit 0. This matters because of the next point.
- **A password change on the mailbox account kills the credential.** Google
  invalidates refresh tokens carrying Gmail scopes when the user changes their
  password. It also dies after six months unused, or on an explicit revoke. The
  fix is always the same: re-run `bin/gmail-oauth-mint` and re-file. Re-minting
  is safe — Google allows 100 live refresh tokens per account per client before
  it begins invalidating the oldest.

The task reports `N matched, M new, K already held`, and names which path it
took (`incremental from <cursor>` or `full sync (…)`). On a quiet mailbox `M` is
0, nothing is stored and no row is touched.

---

## Part 3 — Categorize

Run the intake protocol from [`knowledge-capture.md`](knowledge-capture.md) over
each new item on `/admin/desk`. Gmail differs from the team@ mouth in three ways:

**1. The sender is a counterparty, and that is expected.** The team@ door
quarantines an unknown `From:` because that address is public and guessable. A
Gmail arrival came from Alex's own mailbox, selected by a query we
control, so its `From:` is the subject of the correspondence rather than a red
flag. `source` on the row tells the two apart — check it before reading a
`received` status as an allowlist decision.

**2. Everything in it is a claim.** These are statements by counterparties,
advisors and brokers, captured verbatim — excellent evidence of *what was said
and when*, and not filed facts. Reconcile every figure against what is already
filed and send contradictions to the discrepancy record.

**3. Access defaults to the deal side.** `samson: full`, `dawn: none` unless
there is a reason otherwise. Promoting later is one edit; a leak the other way
is not.

Stamp the outcome on the item exactly as the email leg does — `status` to
`filed` (or `ignored`) and one line in `filed_note` saying what was done and
where it went.

---

## Revoking it — one step

```
myaccount.google.com → Security → Your connections to third-party apps
  → (the OAuth client) → Remove access
```

That is the whole revoke, done from the mailbox owner's own account with no
admin console and no deploy. The next `gmail:pull` then fails loudly with
`invalid_grant` rather than going quiet. Delete the 1Password item too if the
lane is being retired rather than paused.

This one-step, self-service revoke is a *reason* for the identity choice, not a
footnote to it — see below.

---

## Decisions — what was rejected, and why

A later session will be tempted by each of these. They were measured, not
assumed.

**A Gmail filter auto-forwarding the deal cast to `team@` — rejected.** It
sounds like the zero-new-access option and is in fact the broken one. Gmail
auto-forwarding **preserves the original `From:`**, so every forwarded message
would arrive at the team@ door as the counterparty, fail
`DeskCaptureItem.allowlisted?`, and land `quarantined` — body dropped,
attachments never extracted. Sealed raw in a bucket is not knowledge. The two
ways out are worse: widening `DESK_ALLOWED_SENDERS` to third-party addresses on
a **public** address, or trusting a forgeable `X-Forwarded-For`. Note the irony
— hand-forwarding works *because* it makes a new message from Alex, so
automating it breaks the property that made it work.

**A service account with domain-wide delegation — rejected.** DWD **cannot be
scoped to one mailbox**: it authorizes the service account to impersonate any
user in the domain, including super-admins, and the **calling application**
picks the subject via the JWT `sub` claim. That moves "only this mailbox" out of
the grant and into our code, which is the opposite of what this design is for.
Google's own guidance says to use DWD "only when you have a critical business
case that requires an app to bypass user consent," and points at OAuth or
Marketplace apps instead.

**A private Marketplace app admin-installed to a group of one — not measured.**
Admin-install *can* be scoped to specific OUs or groups, which would give
admin-granted scopes with no consent flow AND a narrow grant. What is unverified
is whether that narrows the impersonable user set or merely auto-provisions an
ordinary domain-wide grant. **The experiment that settles it:** install with
`gmail.readonly` to a group containing only the one user, then mint a token with
`sub` set to a DIFFERENT user in the domain and call `users.getProfile`. A
profile means it is DWD wearing a nicer hat; a `403 unauthorized_client` means
it is genuinely narrowed and worth revisiting.

**Drafts in Gmail — declined for THIS lane; built in the Workspace lane
(2026-09-23).** Alex later chose real Gmail drafts, and they were built
on the separate service-account lane that already held `gmail.compose` — not by
widening this reader. See **7. Drafting mailboxes** in
[`workspace-provision`](../agents/steffon/sops/workspace-provision.md). This
lane stays `gmail.readonly`, and the reasoning below still holds for it.
`gmail.compose` covers drafts and send, and no
draft-only scope exists, so a "never sends" guarantee could only be code-deep.
This pipeline's whole job is to read attacker-influenced text from
counterparties; pairing that corpus with an outbound channel in one app is the
trade Alex declined for this lane. The `.eml`-file alternative first
proposed here was never built; the Workspace lane replaced it.

**Pub/Sub push — rejected for now.** `users.watch` must be re-called at least
every 7 days (Google recommends daily) or notifications stop, and it needs a
Pub/Sub topic, an IAM grant to `gmail-api-push@system.gserviceaccount.com`, and
a second public signature-verified webhook. It buys seconds of latency for a
sweep that is run by hand.

---

## Boundaries

- Confidential by default: private buckets, presigned links, **never an
  artifact**, never a public store. This repo is public — the deal cast lives in
  Heroku config, and the tests use synthetic addresses on purpose.
- Read-only, always. No scope in this SOP lets an agent send, draft, label or
  delete, and none should be added without Alex's explicit decision —
  recorded as its own task, with its own credential, so revoking a writer can
  never touch this reader.
- Capture never merges, deploys, or touches the release ladder.
- This is Alex's personal mailbox. Read it for the deal record, not to
  mine it; the query is the boundary, and narrowing it is always allowed.
