# Domain DNS

## Status: Active

This is Steffon's `domain-dns` SOP: publish the records that let a new
domain receive mail through Google Workspace and send it without landing in
spam. Step 3 of [`workspace-launch`](./workspace-launch.md); runnable on its
own.

**Steffon writes every record; Alex pastes them.** Squarespace DNS has
no API, so the paste is his. Steffon then checks each record from the public
internet — a record is published when `dig` sees it, not when the console shows
it.

## Entry

Input: the domain, the Google verification TXT from
[`workspace-signup`](./workspace-signup.md), and the DKIM key (step 2 below).

## 1. Write the records — Steffon

| Host | Type | Value | Why |
|------|------|-------|-----|
| `@` | TXT | `google-site-verification=<from signup>` | proves the domain to Google |
| `@` | MX, priority 1 | `smtp.google.com` | mail arrives at Google |
| `@` | TXT | `v=spf1 include:_spf.google.com ~all` | who may send as the domain |
| `google._domainkey` | TXT | `v=DKIM1; k=rsa; p=<from step 2>` | signs outgoing mail |
| `_dmarc` | TXT | `v=DMARC1; p=none; rua=mailto:team@<domain>` | reports, no blocking yet |

Squarespace adds default records to a new domain (parking and site records).
Remove any **other MX** records; keep the rest unless they conflict.

If the domain will also send app mail through Amazon SES (Pro), the SPF value
gains `include:amazonses.com` — SPF must stay ONE TXT record.

## 2. Generate the DKIM key — Alex

```not-pasteable
🙋 YOUR TURN — generate the DKIM key
   Where:  https://admin.google.com → Apps → Google Workspace → Gmail
           → Authenticate email → Generate new record (2048-bit, prefix "google")
   Enter:  nothing — copy the TXT value it shows and paste it to me
   Done when: Google shows a TXT value starting v=DKIM1
   Then paste it here (it is public, not a secret).
```

## 3. Paste the records — Alex

```not-pasteable
🙋 YOUR TURN — add the DNS records
   Where:  https://account.squarespace.com/domains → <domain> → DNS → Custom records
   Enter:  the five rows from my table, exactly (Host, Type, Priority, Value)
           Delete any other MX record.
   Done when: all five show under Custom records
   Then tell me "done".
```

## 4. Check from the internet — Steffon

```bash
dig +short TXT <domain>                      # verification + SPF
dig +short MX <domain>                       # 1 smtp.google.com.
dig +short TXT google._domainkey.<domain>    # v=DKIM1 …
dig +short TXT _dmarc.<domain>               # v=DMARC1 …
```

Green when all four answer with the values from step 1. DNS can take minutes to
an hour; re-check rather than re-paste. Once green:

```not-pasteable
🙋 YOUR TURN — tell Google to verify and start DKIM
   Where:  admin.google.com → verify the domain (signup banner), then
           Apps → Gmail → Authenticate email → Start authentication
   Done when: domain shows Verified, DKIM shows "Authenticating email"
   Then tell me "done".
```

Record: `bin/task update <launch-task> --checks "[control] domain-dns: MX, SPF, DKIM, DMARC resolve publicly"`.

DMARC starts at `p=none` on purpose. Raise it to `quarantine` after a few weeks
of clean reports — a separate, deliberate change.
