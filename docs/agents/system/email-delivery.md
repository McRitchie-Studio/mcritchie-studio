# Email Delivery (Amazon SES)

Owner: **Steffon**. This is the canonical runbook for the ecosystem's outbound email transport.

## Why SES
Resend charges $20/mo to send from more than one verified domain (we need both `mcritchie.studio` and `turfmonster.media`). **Amazon SES** is `$0.10 / 1,000 emails`, no monthly fee, unlimited verified domains — and we're already on AWS (S3). It backs the McRitchie Studio **Broadcasts** feature (self-owned mailing list + personalized sends) and will replace Resend for transactional mail too.

Transport is selected via env at boot, so apps need no code change to switch — same pattern as `Studio::S3`. **Planned:** lift transport selection into `studio-engine` so both apps inherit it; migrate Turf Monster off Resend by swapping env vars.

## Credential
- 1Password: vault `agents`, item **`agent.aws.mcritchie-ses`** (IAM user `mcritchie-ses`, inline policy `ses-management`, SES-scoped only).
- Region: **us-east-2**.
- Pull:
  ```bash
  export AWS_ACCESS_KEY_ID=$(op item get "agent.aws.mcritchie-ses" --vault agents --fields label="access key" --reveal)
  export AWS_SECRET_ACCESS_KEY=$(op item get "agent.aws.mcritchie-ses" --vault agents --fields label="secret access key" --reveal)
  ```

## Test the key (no aws CLI on this machine)
`aws` CLI isn't installed; sign SES API calls with the app's bundled `aws-sigv4`. Export the creds (above), then:
```bash
bin/rails ses:check
```
Expect `GetAccount → 200`, `SendingEnabled=true`. (Or `brew install awscli` and use `aws sesv2 get-account --region us-east-2`.)

## Setup tasks (open as of 2026-06-06)
Account state: **sandbox** (`ProductionAccessEnabled=false`), **no identities verified**.

1. **Verify a sending domain** (prefer a marketing subdomain to protect magic-link reputation, e.g. `mail.mcritchie.studio`):
   `aws sesv2 create-email-identity --email-identity mail.mcritchie.studio` → add the returned **DKIM CNAME** records to DNS. (DNS is NOT in SES — see DNS note.)
2. **Add SPF + DMARC** for the domain in DNS.
3. **Request production access**: `aws sesv2 put-account-details ...` (or SES console → Account dashboard → Request production access). Lifts the sandbox so you can send to anyone; usually approved < 24h.
4. **Wire the app** (already prototyped in mcritchie-studio):
   - SMTP path: set `SES_SMTP_USERNAME` / `SES_SMTP_PASSWORD` / `SES_SMTP_HOST=email-smtp.us-east-2.amazonaws.com` + `MAILER_FROM` (a verified address) in `.env`. `config/initializers/ses.rb` then takes over; `resend.rb` yields when SES creds are present.
   - SDK path (preferred long-term, one key does everything): send via `aws-sdk-sesv2` using `agent.aws.mcritchie-ses` — no SMTP creds to manage.

## DNS note
DKIM/SPF/DMARC records live at the domain's DNS host, not SES. If DNS is on **Route 53**, grant the IAM user scoped `route53:ChangeResourceRecordSets` and add records via API. If elsewhere (Cloudflare/registrar), use that provider's API or add records manually.

## Deliverability guardrails
- Send marketing from a **subdomain** distinct from transactional/magic-link mail.
- Honor unsubscribes (Broadcasts does this via `Contact#unsubscribe!`); feed SES complaint/bounce notifications (SNS) back into suppression over time.
- Warm up volume gradually on a fresh domain.
