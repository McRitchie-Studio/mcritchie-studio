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

| App | Production app | Local URL | Local inbox | Sender target | Durable outbox |
|-----|----------------|-----------|-------------|---------------|----------------|
| McRitchie Studio | `mcritchie-studio` | `http://localhost:3000` | `http://localhost:3000/_studio/local_emails` | `noreply@mcritchie.studio` | `studio_email_deliveries` / `Studio::EmailDelivery` |
| Turf Monster | `turf-monster-mainnet` | `http://localhost:3100` | `http://localhost:3100/_studio/local_emails` | `noreply@turfmonster.media` | `email_deliveries` / `EmailDelivery` |
| Future apps | TBD | reserve the app's hundred-block | `http://localhost:<port>/_studio/local_emails` | verified app domain or approved shared sender | prefer `studio_email_deliveries` |

McRitchie may still use `noreply@turfmonster.media` on the Resend rollback path
until `mcritchie.studio` is fully verified in SES. Do not add a future app to
real provider delivery until its sender domain is recorded in this matrix.

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
MAILER_FROM=noreply@example.com
RESEND_API_KEY=...       # rollback only
LOCAL_EMAIL_CAPTURE=1    # local/worktree proof mode
```

SES helper tasks use `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and
`SES_REGION` from the same credential item. Runtime delivery uses the SES SMTP
username and password.

## Agent Proof Modes

Use local capture for normal local development and worktree work:

1. Set `LOCAL_EMAIL_CAPTURE=1`.
2. Keep provider mail credentials blank in the worktree stack.
3. Trigger the app flow.
4. Return the app URL and the local inbox URL in the handoff.

Provider smoke tests are explicit, narrower tasks:

1. Set `LOCAL_EMAIL_CAPTURE=0`.
2. Confirm `MAIL_TRANSPORT=ses` and SES SMTP env are present.
3. Send one magic link or transactional email to an approved test inbox.
4. Confirm the message arrives and provider headers show DKIM/SPF/DMARC pass.
5. Return the exact app URL tested plus whether the provider send landed in inbox
   or spam.

Do not ask the user to run terminal commands for these proofs. Ask for approval
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
6. Stage `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, `SES_REGION`, and
   `MAILER_FROM` in the app's environment.
7. Keep `RESEND_API_KEY` present during the migration window.
8. Set `MAIL_TRANSPORT=ses`.
9. Smoke test a magic link.
10. Confirm DKIM/SPF/DMARC pass and delivery does not land in spam.
11. Record any sender-domain change in this doc and the app's email runbook.

Useful app commands:

```bash
bin/rails ses:check
bin/rails "ses:verify_domain[example.com]"
```

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
