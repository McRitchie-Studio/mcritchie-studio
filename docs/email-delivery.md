# Email Delivery - SES Primary, Resend Rollback

McRitchie Studio sends transactional email through ActionMailer. Magic-link
sign-in is currently the critical path. Delivery goes through
`Studio::Email.deliver`, which records a durable `Studio::EmailDelivery` row
before enqueueing the actual send.

Cross-app sender inventory, SES cutover rules, local inbox proof, and rollback
policy live in [`docs/agents/modules/email-operations.md`](agents/modules/email-operations.md).
Keep this file focused on McRitchie-specific wiring.

## Transport Contract

The active transport is chosen by `MAIL_TRANSPORT`:

| `MAIL_TRANSPORT` | Active transport | Notes |
|---|---|---|
| `ses` with SES creds | AWS SES SMTP | Target state. Requires `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, `SES_REGION`. |
| `ses` without SES creds | Resend fallback | Logs a warning; avoids silently breaking login during setup. |
| unset / `resend` | Resend | Rollback path while the Resend account remains available. |

Code:

- `config/initializers/studio_mail_transport.rb` calls `Studio::MailTransport.configure!`.
- `studio-engine` owns `Studio::MailTransport`, `Studio::Email.deliver`, the
  `Studio::EmailDelivery` outbox, the Resend dependency, and the shared `ses:*`
  Rake tasks.

## Local Agent Inbox

In non-production, `studio-engine` exposes a local inbox:

```text
http://localhost:3000/_studio/local_emails
```

Worktree stacks launched through `bin/agent-worktree` set `LOCAL_EMAIL_CAPTURE=1`
and blank provider mail credentials in `.env.agent-stack`. In that mode
`Studio::Email.deliver` records `studio_email_deliveries` rows but does not
enqueue or send external mail. Agents should use the inbox URL as the proof
surface for magic-link/auth work instead of asking the user to check Gmail.

Primary local stacks can opt into the same behavior with `LOCAL_EMAIL_CAPTURE=1`.
Set `LOCAL_EMAIL_CAPTURE=0` only when the task is explicitly testing SES/Resend
provider delivery.

## Durable Outbox

The shared table is `studio_email_deliveries`.

- `sent=false` means the intent was recorded but the mail has not succeeded yet.
- `error` stores the last delivery failure message.
- `Studio::EmailDelivery.resend_unsent!` re-enqueues unsent rows after a
  provider or worker outage.

McRitchie currently uses the Rails `:async` job adapter in production until a
dedicated worker dyno/job backend is added. The durable row still prevents the
send intent from disappearing; operator recovery is the resend command above.

## Credentials

Credential inventory entry:

- `agent.aws.mcritchie-ses` in the `agents` vault: shared SES-scoped AWS credentials, region `us-east-2`.

Environment variables:

- `MAIL_TRANSPORT=ses`
- `SES_REGION=us-east-2`
- `SES_SMTP_USERNAME`
- `SES_SMTP_PASSWORD`
- `SES_AWS_ACCESS_KEY_ID` and `SES_AWS_SECRET_ACCESS_KEY` for `ses:*` checks
- `MAILER_FROM`
- `RESEND_API_KEY` only for rollback.

If `MAILER_FROM` is not set, McRitchie defaults to `noreply@mcritchie.studio`
when `MAIL_TRANSPORT=ses` and `noreply@turfmonster.media` for the Resend
rollback path.

Do not overwrite the app's S3/ImageCache `AWS_ACCESS_KEY_ID` or
`AWS_SECRET_ACCESS_KEY` for SES proof. Use the `SES_AWS_*` variables from
`agent.aws.mcritchie-ses` for account/domain checks.

## Current Production Status

Last checked: 2026-06-14.

- SES account in `us-east-2`: sending enabled, enforcement healthy, still in
  sandbox (`ProductionAccessEnabled=false`).
- `mcritchie.studio`: verified for sending, DKIM `SUCCESS`.
- Persistent production transport: keep Resend active until SES production
  access is approved and SMTP runtime credentials are staged.
- Production app adoption: deploy the current `studio-engine` release before
  proving the shared `Studio::Email.deliver` outbox path on Heroku.

## Cutover Checklist

Use the shared checklist in
[`docs/agents/modules/email-operations.md`](agents/modules/email-operations.md)
first, then apply the McRitchie-specific values below.

1. Confirm SES is out of sandbox in `us-east-2`.
2. Verify `mcritchie.studio` in SES.
3. Publish the SES DKIM CNAMEs, SPF, and DMARC records.
4. Stage `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, `SES_REGION`, and optionally `MAILER_FROM=noreply@mcritchie.studio`.
5. Set `MAIL_TRANSPORT=ses`.
6. Smoke test a magic link to `alex@mcritchie.studio`.
7. Confirm Gmail shows DKIM/SPF/DMARC pass and the message does not land in spam.

Useful checks:

```bash
bin/rails ses:check
bin/rails "ses:verify_domain[mcritchie.studio]"
```

## Rollback

Unset `MAIL_TRANSPORT` or set `MAIL_TRANSPORT=resend`. Resend resumes if
`RESEND_API_KEY` is present.

Do not remove the Resend rollback path until SES has been stable long enough
that the fallback is no longer useful.

## Engine Ownership

McRitchie Studio is bundled with `studio-engine 0.5.6+`, so transport selection,
durable delivery primitives, and the local agent inbox live in the engine. Keep
future shared email changes in `studio-engine` unless they are truly
app-specific.
