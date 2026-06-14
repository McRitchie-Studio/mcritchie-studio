# Shared SES Production Proof - 2026-06-14

Purpose: prove the shared SES account and domain readiness for McRitchie Studio,
Turf Monster, and future apps without cutting production traffic over too early.

## Result

SES domain verification is ready. Full production cutover is not ready.

| Surface | Result |
|---------|--------|
| SES region | `us-east-2` |
| SES account sending | `SendingEnabled=true` |
| SES production access | `ProductionAccessEnabled=false` |
| SES enforcement status | `HEALTHY` |
| `mcritchie.studio` identity | verified for sending, DKIM `SUCCESS` |
| `turfmonster.media` identity | verified for sending, DKIM `SUCCESS` |

## Production App State

| App | Heroku app | Current safe transport | Notes |
|-----|------------|------------------------|-------|
| McRitchie Studio | `mcritchie-studio` | Resend rollback | `MAIL_TRANSPORT` was unset during proof; do not persist SES while sandboxed. |
| Turf Monster | `turf-monster-mainnet` | Resend rollback | `SES_REGION=us-east-2` existed, but persistent SES cutover remains blocked by sandbox mode. |

The production dynos checked during this proof were still loading
`studio-engine 0.5.2`, while local consumer lockfiles were already on
`studio-engine 0.5.6`. Deploy the consumers with the current engine before
proving `Studio::Email.deliver` and the shared outbox path on Heroku.

## Credential Finding

The SES 1Password item is `agent.aws.mcritchie-ses` in the `agents` vault.
It contains SES-scoped AWS API keys. Runtime SMTP username/password fields were
not populated during this proof.

The existing Heroku `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` values pointed
at an S3/ImageCache IAM user, so `bin/rails ses:check` returned AccessDenied on
production. The engine helper now prefers:

```env
SES_AWS_ACCESS_KEY_ID=...
SES_AWS_SECRET_ACCESS_KEY=...
SES_REGION=us-east-2
```

and falls back to `AWS_*` only for older apps.

## Cutover Blockers

1. SES account is still sandboxed. Request or confirm production access before
   setting persistent `MAIL_TRANSPORT=ses` on web dynos.
2. Runtime SES SMTP credentials need to be stored or derived and staged as
   `SES_SMTP_USERNAME` / `SES_SMTP_PASSWORD`.
3. Consumer apps need a deploy with the current `studio-engine` release.
4. After production access and deploy, run one provider smoke test per app and
   confirm DKIM/SPF/DMARC pass.

## Safe Next Proof

After the blockers above are cleared:

1. Set `SES_AWS_ACCESS_KEY_ID` / `SES_AWS_SECRET_ACCESS_KEY` on both Heroku apps.
2. Run `bin/rails ses:check` on both apps and confirm `ProductionAccessEnabled=true`.
3. Stage `MAIL_TRANSPORT=ses` only for a one-off dyno first, not persistent web
   dynos.
4. Send a McRitchie magic link to `alex@mcritchie.studio`.
5. Send a Turf magic link to the approved Turf test inbox.
6. Confirm provider headers and record the final cutover result in
   `docs/agents/modules/email-operations.md`.
