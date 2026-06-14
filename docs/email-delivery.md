# Email Delivery - SES Primary, Resend Rollback

McRitchie Studio sends transactional email through ActionMailer. Magic-link
sign-in is currently the critical path.

## Transport Contract

The active transport is chosen by `MAIL_TRANSPORT`:

| `MAIL_TRANSPORT` | Active transport | Notes |
|---|---|---|
| `ses` with SES creds | AWS SES SMTP | Target state. Requires `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, `SES_REGION`. |
| `ses` without SES creds | Resend fallback | Logs a warning; avoids silently breaking login during setup. |
| unset / `resend` | Resend | Rollback path while the Resend account remains available. |

Code:

- `config/initializers/studio_mail_transport.rb` calls `Studio::MailTransport.configure!`.
- `studio-engine` owns `Studio::MailTransport`, the Resend dependency, and the shared `ses:*` Rake tasks.

## Credentials

Credential inventory entry:

- `agent.aws.mcritchie-ses` in the `agents` vault: SES-scoped AWS credentials, region `us-east-2`.

Environment variables:

- `MAIL_TRANSPORT=ses`
- `SES_REGION=us-east-2`
- `SES_SMTP_USERNAME`
- `SES_SMTP_PASSWORD`
- `MAILER_FROM`
- `RESEND_API_KEY` only for rollback.

## Cutover Checklist

1. Confirm SES is out of sandbox in `us-east-2`.
2. Verify `mcritchie.studio` in SES.
3. Publish the SES DKIM CNAMEs, SPF, and DMARC records.
4. Stage `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, and `SES_REGION`.
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

McRitchie Studio is bundled with `studio-engine 0.5.2+`, so the compatibility
fallback has been removed from the app. Keep future transport changes in
`studio-engine` unless they are truly app-specific.
