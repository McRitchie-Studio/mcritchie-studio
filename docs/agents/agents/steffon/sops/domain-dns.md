# Domain DNS
<!-- registry: verify, MX, SPF, DKIM, DMARC -->

## Status: Active

This is Steffon's `domain-dns` SOP: publish the records that let a new
domain receive mail through Google Workspace and send it without landing in
spam. Step 3 of [`workspace-launch`](./workspace-launch.md); runnable on its
own.

**Steffon writes every record; Alex pastes them.** Squarespace DNS has
no API, so the paste is his. Steffon then checks each record from the public
internet — a record is published when `dig` sees it, not when the console shows
it.

**Growth and above run their DNS on Cloudflare** (Alex, 2026-10-12; the
`Cloudflare DNS` row in `config/workspace_packages.yml`). Once a zone is on
Cloudflare, Steffon writes its records by API and nothing is pasted; moving it
there is [§ Cloudflare DNS — Growth and above](#cloudflare-dns--growth-and-above).
Pro and below stay on Squarespace DNS with the paste steps below. `/stack` shows
each client's live DNS host, so a Growth client not yet moved reads
**Migration pending**.

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

App mail goes through Resend (SES was retired on 2026-10-10); Resend's own
records come from its domain page, not from this table. SPF must stay ONE TXT
record.

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

## Moving a domain's nameservers

- **Check DNSSEC first.** Run `dig DS <domain>` against the TLD's servers. If a
  DS record exists, disable DNSSEC as its own step, watch the TLD until the DS is
  gone, wait its TTL (usually an hour), and only then change nameservers. A DS
  left behind makes every validating resolver fail the whole domain.
- **Copy every record, subdomains included.** Compare the new zone with the old
  one record by record, including rows under subdomains such as `in.` and
  `send.in.`; a missing inbound MX drops mail silently, and dropped mail is not
  redelivered. A provider's "verified" badge is not a DNS check; `dig` against
  the new nameservers is.
- **Have Alex confirm the domain name on the registrar page before every save.**
  Registrar saves reach the registry minutes later, in order, so a save on the
  wrong domain is slow to undo.

## Cloudflare DNS — Growth and above

The bare domain becomes the app's address, `www` and any other domain redirect
at Cloudflare's edge, and every later record is an API call. Live today on
`mcritchie.studio` and `turfmonster.media` (both since 2026-09-30, records DNS
only); `/stack` tracks the rest. The edge-proxy and certificate work beyond DNS
is the separate [CDN rollout](../../../system/cdn-rollout.md); this section
moves DNS only and proxies only `www`, for its redirect, and nothing that serves the app.

The agent token `cloudflare.studio.provision` has DNS read/write on every zone
in the account but **no Zone grant** ([credential
inventory](../../../modules/credential-inventory.md)), so Alex adds the zone and
pastes the nameservers; everything else is Steffon's. The same step, as a
launch prerequisite, is row 0.2 of Rex's
[`launch-warmup`](../../rex/sops/launch-warmup.md).

### 1. Snapshot the live records — Steffon

Before anything moves, record what the domain answers today, from public
resolvers, so step 4 has something to compare against:

```bash
for r in 1.1.1.1 8.8.8.8; do
  dig +short @$r NS <domain>
  dig +short @$r A <domain>; dig +short @$r CNAME www.<domain>
  dig +short @$r MX <domain>; dig +short @$r TXT <domain>
  dig +short @$r TXT google._domainkey.<domain>; dig +short @$r TXT _dmarc.<domain>
done
dig DS <domain> +trace | tail -4          # the TLD's answer: is a DS published?
```

Add every subdomain the client uses (`send.`, `in.`, Resend's records) to the
list; the [moving rules](#moving-a-domains-nameservers) below say why.

### 2. Turn DNSSEC off, then wait — Alex, then Steffon

A DS record left at the TLD after the nameservers move makes every validating
resolver fail the whole domain. It broke `turfmonster.media` for an hour on
2026-09-29 ([`cdn-rollout.md`](../../../system/cdn-rollout.md) step 4).

```not-pasteable
🙋 YOUR TURN — switch DNSSEC off
   Where:  https://account.squarespace.com/domains → <domain> → DNS → DNSSEC
   Enter:  turn DNSSEC off; change nothing else yet
   Done when: Squarespace shows DNSSEC off
   Then tell me "done" — and do NOT paste nameservers until I say so.
```

Steffon then re-runs `dig DS <domain> +trace` until the TLD stops answering a
DS, and waits out its TTL (about an hour) before step 3. Squarespace stops
signing at once; the registry drops the DS minutes to an hour later.

### 3. Add the zone, check the import, paste the nameservers — Alex and Steffon

```not-pasteable
🙋 YOUR TURN — add the zone in Cloudflare
   Where:  https://dash.cloudflare.com → McRitchie Studio account → Add a domain
   Enter:  <domain>, Free plan, let it import the existing records
   Done when: Cloudflare shows two assigned nameservers (*.ns.cloudflare.com)
   Then paste me the two nameservers — and stop there.
```

Steffon reads the imported zone by API and makes it match step 1's snapshot
**exactly**, record by record: the Google MX (`smtp.google.com`), the
`google-site-verification` TXT, SPF as ONE TXT, DKIM, DMARC, Resend's records,
and every subdomain. Every record starts **DNS only** (grey cloud), as on
`turfmonster.media`. Then the app records:

| Host | Type | Value | Proxy |
|------|------|-------|-------|
| `@` | CNAME | the Heroku DNS target (`*.herokudns.com`) from `heroku domains:add <domain> -a <app>` | DNS only — Cloudflare flattens a CNAME at the apex, which Squarespace could not do with DNSSEC on |
| `www` | CNAME | `<domain>` | **Proxied** — an edge redirect rule only runs on proxied traffic, and the redirect answers before Heroku is asked |

Only once the zone matches:

```not-pasteable
🙋 YOUR TURN — move the nameservers (DNSSEC already off)
   Where:  https://account.squarespace.com/domains → <domain> → DNS → Nameservers
   Check:  the domain name on the page is <domain> before you save
   Enter:  Use custom nameservers: the two Cloudflare gave you, exactly
   Done when: Squarespace shows the two Cloudflare nameservers
   Then tell me "done".
```

### 4. Redirect `www` at the edge — Alex

The token has DNS write only, no rules grant, so this is a dashboard click
until the token is widened.

```not-pasteable
🙋 YOUR TURN — add the www redirect
   Where:  dash.cloudflare.com → <domain> → Rules → Redirect Rules → Create
   Enter:  If hostname equals www.<domain>
           Then dynamic redirect to concat("https://<domain>", http.request.uri.path)
           Status 301, preserve query string. (Repeat per extra domain to forward.)
   Done when: the rule shows Active
   Then tell me "done".
```

### 5. Move the app to the bare domain — Steffon

```bash
heroku domains:add <domain> -a <app>              # if step 3 has not already
heroku config:set APP_HOST=<domain> -a <app>      # plus APP_HOST_ALIASES (or the app's
                                                  # own allowed-host list) keeping www.<domain>
heroku certs:auto:refresh -a <app>                # re-issue ACM for the bare domain
heroku certs:auto -a <app>                        # wait for every domain to read "OK"
```

What `APP_HOST` drives (mailer links, the Google callback) is in
[`deployment.md`](../../../modules/deployment.md); a host change there may owe
a new authorized redirect URI. Retire the old Squarespace domain forwarding only
after step 6 is green.

### 6. Verify against public resolvers — Steffon

```bash
for r in 1.1.1.1 8.8.8.8; do
  dig +short @$r NS <domain>                      # *.ns.cloudflare.com
  dig +short @$r MX <domain>                      # 1 smtp.google.com. (unchanged)
  dig +short @$r TXT <domain>                     # verification + the one SPF (unchanged)
  dig +short @$r TXT google._domainkey.<domain>   # unchanged
done
dig DS <domain> +trace | tail -4                  # still no DS
curl -sS -o /dev/null -w "%{http_code}\n" https://<domain>/up                         # 200
curl -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" https://www.<domain>/x?y=1   # 301 https://<domain>/x?y=1
```

Green when every mail and verification record matches step 1's snapshot, the
bare domain answers `200` over HTTPS, and `www` answers `301` to the bare
domain with its path. `/stack` then shows the client **On Cloudflare**.

Record: `bin/task update <launch-task> --checks "[control] domain-dns: <domain> on Cloudflare, mail records unchanged, www 301s to the bare domain"`.

