# Shared SES Production Proof - 2026-06-14

Purpose: prove the shared SES account and domain readiness for McRitchie Studio,
Turf Monster, and future apps without cutting production traffic over too early.

## Result

SES domain verification is ready. Full production cutover is not ready because
the account remains sandboxed and runtime SMTP credentials still need a smoke
window. Production fallback delivery is proved through Resend on the verified
`mcritchie.studio` domain.

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
| McRitchie Studio | `mcritchie-studio` | Resend fallback | `MAIL_TRANSPORT` is unset; `bin/rails ses:check` uses `CredentialSource=SES_AWS_ACCESS_KEY_ID`, returns SES `HTTP 200`, and reports `ProductionAccessEnabled=false`. |
| Turf Monster | `turf-monster-mainnet` | Resend fallback | `MAIL_TRANSPORT` is unset; release `v93` proved `transport=Resend from=McRitchie Studio <team@mcritchie.studio>` on Heroku-26, and `bin/rails ses:check` now reaches SES with `HTTP 200`. |

Updated 2026-06-14: consumer deploys now run `studio-engine 0.5.9`. Turf
Monster release `v93` re-proved the shared mail boot path and successful
production fallback posture during the Heroku-26 rebuild. Keep Resend configured
until SES has production access and a stability window.

Updated 2026-06-15: live Heroku `ses:check` tasks were run on both apps after
staging `SES_AWS_ACCESS_KEY_ID` / `SES_AWS_SECRET_ACCESS_KEY` from
`agent.aws.mcritchie-ses`. Both apps keep `MAIL_TRANSPORT` unset and therefore
use Resend fallback. Both apps now report `CredentialSource=SES_AWS_ACCESS_KEY_ID`,
`GetAccount -> HTTP 200`, `SendingEnabled=true`, `ProductionAccessEnabled=false`,
and `Enforcement=HEALTHY`.

The released helper prints the `ListEmailIdentities` rows as `pending`, but a
direct SES v2 identity-list proof with the same credentials reports
`mcritchie.studio` and `turfmonster.media` as `VerificationStatus=SUCCESS` and
`SendingEnabled=true`. Treat that as a helper display bug until the next
`studio-engine` maintenance release updates the field name.

## Sender Convention

Updated 2026-06-14:

| Domain | Transactional sender | Marketing sender |
|--------|----------------------|------------------|
| `mcritchie.studio` | `McRitchie Studio <team@mcritchie.studio>` | `Alex McRitchie <alex@mcritchie.studio>` |
| `turfmonster.media` | `Turf Monster <team@turfmonster.media>` | `Alex from Turf Monster <alex@turfmonster.media>` |

Transactional means auth, security, account, receipt, and contest-result mail.
Marketing means newsletter, broadcast, or launch-update mail. Avoid `noreply@`
senders; use `Reply-To` or a monitored support address when a different reply
path is needed.

## AWS Follow-Up Draft

Use this as the next support-case reply if AWS has not answered the June 11
details yet:

```text
Hi AWS team,

Following up on this SES production access request for us-east-2.

We provided the requested sending-process details on June 11. We also finalized
our sender convention so recipient expectations are clear:

- Turf Monster transactional email: Turf Monster <team@turfmonster.media>
- Turf Monster newsletter/marketing email: Alex from Turf Monster <alex@turfmonster.media>
- McRitchie Studio transactional email: McRitchie Studio <team@mcritchie.studio>
- McRitchie Studio marketing or product-update email: Alex McRitchie <alex@mcritchie.studio>

All sending remains low-volume, event-driven, and permission-based. Auth,
security, account, receipt, and contest-result mail is sent only to registered
users in response to user/account activity. Newsletter mail is explicit opt-in
and includes account-level preferences/unsubscribe handling.

We are keeping Resend as the rollback provider and will cut over to SES only
after production access is approved and one-off provider smoke tests pass. Our
initial requested volume remains modest: under 200 messages/day.

Please let us know if you need any additional sender-domain, DNS, content, or
bounce/complaint workflow details to complete review.

Thank you.
```

## Credential Finding

The SES 1Password item is `agent.aws.mcritchie-ses` in the `agents` vault.
It contains SES-scoped AWS API keys. Runtime SMTP username/password fields were
not populated during this proof.

The existing Heroku `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` values pointed
at an S3/ImageCache IAM user, so `bin/rails ses:check` returned AccessDenied on
production before the SES-specific keys were staged. The engine helper now
prefers:

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
3. After production access, run one provider smoke test per app and
   confirm DKIM/SPF/DMARC pass.

## Safe Next Proof

After the blockers above are cleared:

1. Run `bin/rails ses:check` on both apps after AWS responds and confirm
   `ProductionAccessEnabled=true`.
2. Stage `MAIL_TRANSPORT=ses` only for a one-off dyno first, not persistent web
   dynos.
3. Send a McRitchie magic link to `alex@mcritchie.studio`.
4. Send a Turf magic link to the approved Turf test inbox.
5. Confirm provider headers and record the final cutover result in
   `docs/agents/modules/email-operations.md`.
