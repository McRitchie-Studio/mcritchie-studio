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
| Turf Monster | `turf-monster-mainnet` | `http://localhost:3100` | `http://localhost:3100/_studio/local_emails` | `Turf Monster <team@turfmonster.media>` | `Alex from Turf Monster <alex@turfmonster.media>` | `email_deliveries` / `EmailDelivery` |
| Future apps | TBD | reserve the app's hundred-block | `http://localhost:<port>/_studio/local_emails` | `App Name <team@app-domain>` | `Alex McRitchie <alex@app-domain>` or app-owned marketer | prefer `studio_email_deliveries` |

Transactional auth/security/account emails should use the `team@` convention.
Marketing, newsletter, or broadcast emails should use an `alex@` sender when the
copy is intended to feel personal. Do not add a future app to real provider
delivery until its sender domain is recorded in this matrix.

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

Transactional email is the active shared surface today. Future marketing or
broadcast email should reuse the same SES/provider policy, but the product
model can stay app-owned.

A historical branch, `feat/broadcasts`, contains an old McRitchie Studio
broadcast prototype: contacts, broadcast drafts, unsubscribe routes, delivery
tracking, hero assets, and SES helper tasks. Do not merge that branch wholesale;
it predates the current agent docs, shared engine email outbox, and registry
tooling. If the broadcast idea comes back, reimplement or cherry-pick narrowly
on top of current `main`.

Minimum rules for a revived broadcast surface:

1. Keep unsubscribe and privacy behavior in the first implementation.
2. Use `Studio::Email.deliver` or the current shared transport layer.
3. Keep real provider delivery explicit; local/worktree proof should still use
   `LOCAL_EMAIL_CAPTURE=1`.
4. Keep templates and campaign copy in the owning app.
5. Add provider smoke proof before sending to a real list.

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

If local capture looks empty, check `LOCAL_EMAIL_CAPTURE`, the app's route for
`/_studio/local_emails`, and whether the code path uses `Studio::Email.deliver`.

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
