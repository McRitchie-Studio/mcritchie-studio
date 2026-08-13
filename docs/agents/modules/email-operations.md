# Shared Email Operations

McRitchie Studio owns the cross-app email operating playbook. `studio-engine`
owns the shared Rails mechanics: `Studio::MailTransport`, `Studio::Email.deliver`,
the local agent inbox, SES helper tasks, and the engine outbox model.

Keep app-specific templates, copy, previews, and sender defaults in the owning
app. Keep provider selection, recovery rules, and cross-app sender inventory
here.

## Source Of Truth

| Need | Canonical doc |
|------|---------------|
| Shared provider contract | `studio-engine/docs/EMAIL_TRANSPORT.md` |
| McRitchie implementation notes | `mcritchie-studio/docs/email-delivery.md` |
| Turf Monster implementation notes | `turf-monster/docs/email-delivery.md` |
| Credential item names | `mcritchie-studio/docs/agents/modules/credential-inventory.md` |
| Local ports and worktree stacks | `mcritchie-studio/docs/agents/modules/ports-and-processes.md` |

## App Matrix

| App | Production app | Local URL | Local inbox | Transactional sender | Marketing sender | Durable outbox |
|-----|----------------|-----------|-------------|----------------------|------------------|----------------|
| McRitchie Studio | `mcritchie-studio` | `http://localhost:3000` | `http://localhost:3000/_studio/local_emails` | `McRitchie Studio <team@mcritchie.studio>` | `Alex McRitchie <alex@mcritchie.studio>` | `studio_email_deliveries` / `Studio::EmailDelivery` |
| Turf Monster | `turf-monster-mainnet` | `http://localhost:3100` | `http://localhost:3100/_studio/local_emails` | `Turf Monster <team@turfmonster.media>` | `Alex from Turf Monster <alex@turfmonster.media>` | `email_deliveries` / `EmailDelivery` (legacy, see below) |
| McRitchie Industries | `mcritchie-industries` | `http://localhost:3500` | `http://localhost:3500/_studio/local_emails` | `McRitchie Industries <team@mcritchie.studio>` | n/a | `studio_email_deliveries` / `Studio::EmailDelivery` |
| Moms App | `obscure-plains-6405` | `http://localhost:3000` (unallocated — `bin/dev` defaults to 3000 and collides with the hub) | `http://localhost:<port>/_studio/local_emails` | `Moms App <team@mcritchie.studio>` | n/a | `studio_email_deliveries` / `Studio::EmailDelivery` |
| Future apps | TBD | reserve the app's hundred-block | `http://localhost:<port>/_studio/local_emails` | `App Name <team@app-domain>` | `Alex McRitchie <alex@app-domain>` or app-owned marketer | `studio_email_deliveries` — install it, see below |

Transactional auth/security/account emails should use the `team@` convention.
Marketing, newsletter, or broadcast emails should use an `alex@` sender when the
copy is intended to feel personal. Do not add a future app to real provider
delivery until its sender domain is recorded in this matrix.

**Turf Monster's `email_deliveries` is legacy, not drift.** `Studio::Email.deliver`
checks for a top-level `EmailDelivery` constant FIRST and hands off to it, so an
app that predates the engine outbox keeps its own table and its inbox works
normally. Leave it — converting is a data migration with no user-visible payoff
(operator call, 2026-08-08). Every other app uses the engine table.

### The outbox is a standard — install it

Every engine-consuming app must install the engine's migrations, and re-install
after an engine upgrade:

```bash
bundle update --conservative studio-engine   # resolve FIRST — see below
bin/rails studio_engine:install:migrations   # copies db/migrate/*.studio_engine.rb
bin/rails db:migrate
bin/rails runner 'puts Studio::EmailDelivery.available?'   # => true
```

**Resolve before you copy.** `install:migrations` copies from the gem bundler
RESOLVED. On a branch whose `Gemfile.lock` still pins the older version,
`bundle install` HONOURS that lock and the task copies nothing — a silent no-op
that leaves the suite green. `bundle update --conservative studio-engine` moves
that one gem; read the lockfile diff and confirm nothing else moved.

**Install all of them.** The task copies every engine migration, not just the
outbox, and all of them are safe on any app: the ones that create tables add a
table you may not use yet, and the two that ALTER app-owned tables guard
themselves — `allow_null_image_cache_owner` no-ops when `image_caches` is absent
(studio-engine >= 0.30.1 — before that it raised and failed the whole run), and
`add_standard_user_profile_columns` (0.46+) returns early without a `users` table
and adds every column `if_not_exists`, so an app that already has `first_name`
keeps its own.

Do **not** slim the set by deleting copies you think you don't need.
`install:migrations` builds its skip-list from the files **present**, so a
deleted copy comes back with a fresh timestamp on the next upgrade. Deletion is
not durable, which is why the guard lives in the migration instead.

**Skipping this fails silently.** `Studio::Email.deliver` records a row only when
`studio_email_deliveries` EXISTS; without it, delivery falls through to a plain
async `deliver_later` with no error and no record — the app drops every captured
email and `/_studio/local_emails` is always empty. That was a real bug in
mcritchie-industries, found and fixed 2026-08-08.

### Reaching the inbox — dev only, by design

The local inbox is a **developer-desk** tool, not a QA one.
`Studio.local_tool_enabled?` closes the viewer whenever `Rails.env.production?`
**and** for any request that did not come from the loopback interface. QA apps
run `RAILS_ENV=production` and serve remote requests, so `/_studio/local_emails`
answers **404 on QA** — and `Studio.local_email_capture?` carries the same
production hard-close, so **setting `LOCAL_EMAIL_CAPTURE=1` on a QA dyno does
nothing**. QA sends real mail through the real transport.

This is deliberate: both gates hand out sign-in material without authenticating
anyone. The shared environment banner
(`studio/banners/environment`, studio-engine >= 0.30) is built around the same
fact — it links the inbox only where the viewer resolves, and degrades to an
inert status chip on QA rather than advertising a dead link.

## Credential Map

Do not print secret values in docs, logs, or handoffs.

| Credential | Location | Used for |
|------------|----------|----------|
| `agent.aws.mcritchie-ses` | `agents` 1Password vault | Shared SES-scoped AWS credentials, region `us-east-2` |
| `RESEND_API_KEY` | app env / Heroku config | Rollback provider only |

Runtime mail env:

```env
MAIL_TRANSPORT=ses
SES_REGION=us-east-2
SES_SMTP_USERNAME=...
SES_SMTP_PASSWORD=...
MAILER_FROM="App Name <team@example.com>"
MARKETING_MAILER_FROM="Alex from App Name <alex@example.com>"
RESEND_MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"
RESEND_API_KEY=...       # rollback only
LOCAL_EMAIL_CAPTURE=1    # local/worktree proof mode
```

`RESEND_MAILER_FROM` is the shared fallback sender for apps that are waiting on
SES production access or have not completed their own SES setup yet. Keep
`MAILER_FROM` and `MARKETING_MAILER_FROM` app/domain-specific for the SES target
state; do not make future apps buy/verify extra Resend domains just to send
pre-SES auth mail.

The fallback sender is only valid if its domain is verified in the same Resend
account as `RESEND_API_KEY`. A successful app response (`{"success":true}` from
`POST /magic_link`) proves only that the app accepted the send intent; it does
not prove provider delivery. A provider smoke is complete only when the durable
outbox job finishes successfully and the provider accepts the message.

SES helper tasks use SES API credentials:

```env
SES_AWS_ACCESS_KEY_ID=...
SES_AWS_SECRET_ACCESS_KEY=...
SES_REGION=us-east-2
```

The engine falls back to `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for older
apps, but production should prefer `SES_AWS_*` so an app's S3/ImageCache IAM user
is not mistaken for the SES verification user. Runtime delivery uses the SES
SMTP username and password, which are a separate credential pair.

## Current SES Production Proof

Last checked: 2026-06-15.

| Check | Result |
|-------|--------|
| SES region | `us-east-2` |
| SES account sending | `SendingEnabled=true` |
| SES production access | `ProductionAccessEnabled=false` |
| SES enforcement | `HEALTHY` |
| `mcritchie.studio` identity | verified for sending, DKIM `SUCCESS` |
| `turfmonster.media` identity | verified for sending, DKIM `SUCCESS` |
| Resend fallback domain | `mcritchie.studio` verified in the Resend account backing production apps |

Conclusion: domain verification is ready, but production cutover is still
blocked. Do not set persistent `MAIL_TRANSPORT=ses` on production web dynos
until SES production access is approved and runtime SMTP credentials have passed
a one-off provider smoke test; sandbox mode can send only to verified recipient
identities/domains and would break normal user mail.

Live production check, 2026-06-15:

- McRitchie Studio and Turf Monster both have `MAIL_TRANSPORT` unset, so live
  mail stays on Resend fallback.
- `SES_AWS_ACCESS_KEY_ID` / `SES_AWS_SECRET_ACCESS_KEY` are staged on both
  Heroku apps from `agent.aws.mcritchie-ses`.
- `bin/rails ses:check` on both Heroku apps now uses
  `CredentialSource=SES_AWS_ACCESS_KEY_ID` and returns `HTTP 200` for
  `ses:GetAccount` and `ses:ListEmailIdentities`.
- `GetAccount` reports `SendingEnabled=true`,
  `ProductionAccessEnabled=false`, and `Enforcement=HEALTHY`.
- A direct SES v2 identity-list proof with the same credentials reports both
  `mcritchie.studio` and `turfmonster.media` as `VerificationStatus=SUCCESS`
  and `SendingEnabled=true`. The currently released helper may display those
  identity-list rows as `pending` because it reads the older
  `VerifiedForSendingStatus` field instead of `VerificationStatus`.
- Keep `MAIL_TRANSPORT` unset while AWS production access remains unresolved.

Production proof gaps:

1. Store or derive SES SMTP credentials for each runtime environment.
2. Keep consumer apps on the current `studio-engine` release before proofing a
   provider cutover. Turf Monster release `v93` proved the shared mail boot path
   through Resend fallback; the remaining production proof is SES after sandbox
   removal and SMTP credential staging.
3. Request or confirm SES production access approval, then run a provider smoke
   test to `alex@mcritchie.studio` and a Turf-approved inbox.

## Agent Proof Modes

Use real provider delivery for primary local stacks:

1. Set `LOCAL_EMAIL_CAPTURE=0`.
2. Confirm `RESEND_API_KEY` and `RESEND_MAILER_FROM` are present while SES is
   blocked by sandbox access.
3. Trigger the app flow.
4. Verify the latest delivery row is `sent=true` with no error.
5. Return the app URL tested and the target inbox so Mr. McRitchie can check inbox
   or spam when visual confirmation is needed.

Use local capture for parallel worktree stacks or tasks that should not email
real recipients:

1. Set `LOCAL_EMAIL_CAPTURE=1`.
2. Keep provider mail credentials blank in the worktree stack.
3. Trigger the app flow.
4. Return the app URL and the local inbox URL in the handoff.

Provider smoke tests are explicit, narrower tasks:

1. Set `LOCAL_EMAIL_CAPTURE=0`.
2. Confirm the intended provider env is present (`RESEND_API_KEY` plus a
   verified `RESEND_MAILER_FROM` domain while SES is sandboxed, or
   `MAIL_TRANSPORT=ses` plus SES SMTP env after cutover).
3. Run `bin/rails "email:smoke[approved-test-inbox@example.com]"` from the app.
4. Confirm the durable outbox job finished with no provider error.
5. Confirm the message arrives and provider headers show DKIM/SPF/DMARC pass
   when proving SES.
6. Return the exact app URL tested plus whether the provider send landed in
   inbox or spam.

The smoke task sends one direct ActionMailer message through the current
transport and refuses capture/test/file modes by default. Use
`EMAIL_SMOKE_ALLOW_NON_EXTERNAL=1` only for explicit capture-mode proof, not for
provider proof.

Resend fallback verification, if delivery fails with "domain is not verified":

```bash
dig +short TXT resend._domainkey.mcritchie.studio
dig +short MX send.mcritchie.studio
dig +short TXT send.mcritchie.studio
```

Those public records must match Resend's domain page. Then trigger verification
in Resend and wait for the domain status to become `verified` before retrying
app email. Do not switch fallback senders to an app domain unless that domain is
also present and verified in the active Resend account.

Do not ask Mr. McRitchie to run terminal commands for these proofs. Ask for approval
or external access only when the agent cannot perform the check directly.

## SES Cutover Checklist

Run this once per sending domain.

1. Confirm SES production access in `us-east-2`; sandbox mode can send only to
   verified recipients.
2. Verify the sending domain in SES.
3. Publish the three SES DKIM CNAME records.
4. Publish SPF with Amazon SES included.
5. Publish a DMARC record before production send; `p=none` is acceptable during
   observation, but the record must exist.
6. Stage `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, `SES_REGION`, and the sender
   env in the app's environment (`MAILER_FROM` for transactional mail, and
   `MARKETING_MAILER_FROM` where the app sends marketing/newsletter mail).
7. Keep `RESEND_API_KEY` and `RESEND_MAILER_FROM` present during the migration
   window.
8. Set `MAIL_TRANSPORT=ses`.
9. Smoke test a magic link.
10. Confirm DKIM/SPF/DMARC pass and delivery does not land in spam.
11. Record any sender-domain change in this doc and the app's email runbook.

Useful app commands:

```bash
bin/rails ses:check
bin/rails "ses:verify_domain[example.com]"
bin/rails "email:smoke[approved-test-inbox@example.com]"
```

## Marketing And Broadcast Email

Marketing and broadcast surfaces reuse the same provider policy as
transactional email, but the product model stays app-owned. McRitchie Studio
owns `Broadcast`, `Contact`, `BroadcastDelivery`, unsubscribe routes,
engagement tracking, campaign templates, and S3-hosted email assets.

Minimum rules for broadcast surfaces:

1. Keep unsubscribe and privacy behavior in the first implementation.
2. Use the current shared transport layer; do not add app-local provider
   initializers.
3. Keep real provider delivery explicit; local/worktree proof should still use
   `LOCAL_EMAIL_CAPTURE=1`.
4. Keep templates, campaign copy, and marketing sender defaults in the owning
   app.
5. Generate unsubscribe, open-pixel, and click-tracking URLs from the app's
   mailer host defaults so QA/worktree links do not point at production.
   Use `BROADCAST_HOST` only for an intentional campaign-specific host override.
6. Add provider smoke proof before sending to a real list.

## Recovery

If provider delivery fails but the app accepted the send intent, inspect the
durable outbox first.

McRitchie Studio:

```bash
bin/rails runner 'Studio::EmailDelivery.resend_unsent!'
```

Turf Monster:

```bash
bin/rails runner 'EmailDelivery.resend_unsent!'
```

If local capture looks empty, check these in order — the first one is the
cause that actually bit us, and the only one that fails **silently**:

1. **Is the outbox table installed?** `bin/rails runner 'puts
   Studio::EmailDelivery.available?'`. `false` means the app never ran
   `bin/rails studio_engine:install:migrations`, so `Studio::Email.deliver` has been
   falling through to a plain `deliver_later` — no row, no error, empty inbox.
   (mcritchie-industries, 2026-08-08.)
2. **Is capture on?** `LOCAL_EMAIL_CAPTURE` or `AGENT_WORKTREE` truthy — and
   remember both are ignored under `Rails.env.production?`.
3. **Is the route drawn?** `/_studio/local_emails`, and the request must come
   from loopback (the page 404s otherwise).
4. **Does the code path use `Studio::Email.deliver`?** A mailer called directly
   with `deliver_later` bypasses the outbox by design.

## Rollback And Decommission

Rollback is intentionally simple while Resend remains available:

```bash
MAIL_TRANSPORT=resend
```

Unsetting `MAIL_TRANSPORT` also resumes Resend when `RESEND_API_KEY` is present.

Do not remove Resend env or dependencies until each production app has:

1. At least 30 days of stable SES delivery.
2. One successful provider smoke test after a deploy.
3. One documented rollback drill.
4. No open deliverability issues for its sender domain.

When those are true, open a cleanup issue or audit item before removing Resend
from code or infrastructure.
