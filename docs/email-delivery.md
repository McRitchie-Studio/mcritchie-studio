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

## Local Email Delivery

Primary local stacks send real email through the configured provider by default.
Keep `LOCAL_EMAIL_CAPTURE=0` in the primary `.env` when testing sign-in or
transactional flows locally. While SES production access is pending, that means
Resend sends from `McRitchie Studio <team@mcritchie.studio>`.

In non-production, `studio-engine` also exposes a local inbox:

```text
http://localhost:3000/_studio/local_emails
```

Worktree stacks launched through `bin/agent-worktree` still set
`LOCAL_EMAIL_CAPTURE=1` and blank provider mail credentials in
`.env.agent-stack`. In that mode
`Studio::Email.deliver` records `studio_email_deliveries` rows but does not
enqueue or send external mail. Agents should use the inbox URL as the proof
surface for magic-link/auth work instead of asking the user to check Gmail.

Set `LOCAL_EMAIL_CAPTURE=1` only when intentionally using local inbox capture.

## Durable Outbox

The shared table is `studio_email_deliveries`.

- `sent=false` means the intent was recorded but the mail has not succeeded yet.
- `error` stores the last delivery failure message.
- `Studio::EmailDelivery.resend_unsent!` re-enqueues unsent rows after a
  provider or worker outage.

Production enqueues mail through Solid Queue. The queue tables live in the
primary Postgres database so Heroku release migrations create and migrate them
with the rest of the app. Keep one `worker` dyno scaled for normal delivery:

```bash
heroku ps:scale worker=1 --app mcritchie-studio
```

If a provider or worker outage interrupts sends, the durable row still prevents
the send intent from disappearing; operator recovery is the resend command
above.

## Credentials

Credential inventory entry:

- `agent.aws.mcritchie-ses` in the `studio-agents` vault: shared SES-scoped AWS credentials, region `us-east-2`.

Environment variables:

- `MAIL_TRANSPORT=ses`
- `SES_REGION=us-east-2`
- `SES_SMTP_USERNAME`
- `SES_SMTP_PASSWORD`
- `SES_AWS_ACCESS_KEY_ID` and `SES_AWS_SECRET_ACCESS_KEY` for `ses:*` checks
- `MAILER_FROM`
- `MARKETING_MAILER_FROM`
- `BROADCAST_HOST` only if broadcast unsubscribe/tracking links should use a
  host different from `MAILER_HOST`
- `RESEND_MAILER_FROM`
- `RESEND_API_KEY` only for rollback.

SES uses `MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"`.
Newsletter/product-update mail can use
`MARKETING_MAILER_FROM="Alex McRitchie <alex@mcritchie.studio>"`. Resend
fallback uses `RESEND_MAILER_FROM="McRitchie Studio
<team@mcritchie.studio>"`, which is also the shared fallback sender for future
apps before their SES setup is complete. This fallback is valid only while
`mcritchie.studio` is verified in the Resend account backing `RESEND_API_KEY`.
Broadcast unsubscribe, open-pixel, and click-tracking links use Action Mailer's
default URL options, so QA inherits `MAILER_HOST=qa.mcritchie.studio` and
worktrees inherit `APP_PORT`. Set `BROADCAST_HOST` only for an intentional
campaign-specific host override.
An app-level success response does not prove delivery; the provider smoke must
also show the durable email job completing without a Resend error.

Do not overwrite the app's S3/ImageCache `AWS_ACCESS_KEY_ID` or
`AWS_SECRET_ACCESS_KEY` for SES proof. Use the `SES_AWS_*` variables from
`agent.aws.mcritchie-ses` for account/domain checks.

## Verifying a List Before a Broadcast

An old list bounces. The Cyvasse relaunch's first 101 sends on 2026-09-29
hard-bounced 12 (11.9%), which threatens the sending domain's reputation, so
`cyvasse-legacy` is now a **verified-only audience**
(`Broadcast::VERIFIED_AUDIENCES`): `broadcasts:send_batch` and the editor's
send reach only contacts that ZeroBounce called `valid`. `catch-all`,
`unknown` and unchecked contacts wait. `ONLY_VERIFIED=0` turns the filter off
for one batch run; `ONLY_VERIFIED=1` turns it on for any audience.

`bin/rails "contacts:verify[limit,source_csv]"` (`Contacts::Verification`)
submits one bulk file to ZeroBounce, polls it, and stores each verdict on the
contact (`verification_status`, `verification_sub_status`, `verified_at`).
`invalid`, `spamtrap`, `abuse` and `do_not_mail` are unsubscribed with reason
`verification`, and `BroadcastSendJob` never mails such an address, even one
resubscribed since. A verified contact is never resubmitted, the balance is
checked before submitting, and `FILE_ID=<id>` resumes a submitted file without
spending again. `DRY_RUN=1` picks and reports only. The key is
`ZEROBOUNCE_API_KEY` (`zerobounce.studio.applications`).

Who goes first is the most recently active player.
`script/contacts/cyvasse_last_active.rb` runs read-only on the cyvasse app and
prints `email,last_active_at`, where the time is the later of `users.updated_at`
and the player's last match move. The legacy import kept the old app's
`updated_at`, which tracked its `last_active` stamp; the script's header has the
measurements. From the hub checkout:

```bash
# 1. Recency, read-only from cyvasse (about 18.8k rows).
heroku run -a cyvasse --no-tty -- bash -c 'cat > /tmp/a.rb; bin/rails runner /tmp/a.rb' \
  < script/contacts/cyvasse_last_active.rb | grep '^CYV,' | cut -c5- > tmp/cyvasse-last-active.csv

# 2. Dry run on production: the pick and the balance, nothing spent or written.
heroku run -a mcritchie-studio --no-tty -e DRY_RUN=1 -- \
  bash -c 'cat > /tmp/recency.csv; bin/rails "contacts:verify[10000,/tmp/recency.csv]"' < tmp/cyvasse-last-active.csv

# 3. The real run (about 10k credits; it waits for ZeroBounce, which can take an hour).
heroku run -a mcritchie-studio --no-tty -- \
  bash -c 'cat > /tmp/recency.csv; bin/rails "contacts:verify[10000,/tmp/recency.csv]"' < tmp/cyvasse-last-active.csv

# If the dyno dies after "submitted … as file <id>", resume without resubmitting.
# Detached survives a dropped session; read it with `heroku logs -a mcritchie-studio --tail`.
heroku run:detached -a mcritchie-studio -e FILE_ID=<id> -- bin/rails "contacts:verify[10000]"

# 4. Check what a batch would now take; only verified-valid contacts are picked.
heroku run -a mcritchie-studio -- bin/rails "broadcasts:batch_status[cyvasse-is-back]"
```

**Never rerun a real run to recover one that failed; that spends the credits
twice.** A submit that errors (a timeout, say) may still have landed, and a
dropped session can lose the id. Before any rerun, open the ZeroBounce
dashboard's bulk file list: if the file is there, resume it with `FILE_ID`.

Delete `tmp/cyvasse-last-active.csv` afterwards: it holds every player's email.
Delete the uploaded file in the ZeroBounce dashboard too, once its results are
applied: ZeroBounce keeps the roughly 10k addresses otherwise.

## Current Production Status

Last checked: 2026-06-15.

- SES account in `us-east-2`: sending enabled, enforcement healthy, still in
  sandbox (`ProductionAccessEnabled=false`).
- `mcritchie.studio`: verified for sending, DKIM `SUCCESS`.
- Resend fallback domain: `mcritchie.studio` verified in the active Resend
  account.
- Persistent production transport: keep Resend active until SES production
  access is approved and SMTP runtime credentials are staged.
- Production app adoption: `studio-engine 0.6.0` is adopted. McRitchie Studio
  records durable `Studio::EmailDelivery` rows and uses Solid Queue for
  production job durability.

## Cutover Checklist

Use the shared checklist in
[`docs/agents/modules/email-operations.md`](agents/modules/email-operations.md)
first, then apply the McRitchie-specific values below.

1. Confirm SES is out of sandbox in `us-east-2`.
2. Verify `mcritchie.studio` in SES.
3. Publish the SES DKIM CNAMEs, SPF, and DMARC records.
4. Stage `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, `SES_REGION`, `MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"`, and `RESEND_MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"`.
5. Set `MAIL_TRANSPORT=ses`.
6. Smoke test the provider with `bin/rails "email:smoke[alex@mcritchie.studio]"`.
7. Smoke test a full magic-link sign-in to `alex@mcritchie.studio`.
8. Confirm Gmail shows DKIM/SPF/DMARC pass and the message does not land in spam.

Useful checks:

```bash
bin/rails ses:check
bin/rails "ses:verify_domain[mcritchie.studio]"
bin/rails "email:smoke[alex@mcritchie.studio]"
```

## Rollback

Unset `MAIL_TRANSPORT` or set `MAIL_TRANSPORT=resend`. Resend resumes if
`RESEND_API_KEY` is present.

Do not remove the Resend rollback path until SES has been stable long enough
that the fallback is no longer useful.

## Engine Ownership

McRitchie Studio currently uses `studio-engine 0.6.0`, so transport selection,
durable delivery primitives, the local agent inbox, and provider smoke testing
live in the engine. Keep future shared email changes in `studio-engine` unless
they are truly app-specific.
