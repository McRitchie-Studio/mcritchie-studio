# Domain DNS
<!-- registry: verify, MX, SPF, DKIM, DMARC -->

## Status: Active

This is Steffon's `domain-dns` SOP: publish the records that let a new
domain receive mail through Google Workspace and send it without landing in
spam. Step 3 of [`workspace-launch`](./workspace-launch.md); runnable on its
own.

**Steffon writes every record; Alex pastes them.** Squarespace DNS has
no API, so the paste is his. Steffon then checks each record from the public
internet — a record is published when a public resolver sees it over DoH, not
when the console shows it.

**Pro and above run their DNS on Cloudflare** (Alex, 2026-10-12, set on Growth, which Pro and Team replaced the same day; the
`Cloudflare DNS` row in `config/workspace_packages.yml`). Once a zone is on
Cloudflare, Steffon writes its records by API and nothing is pasted; moving it
there is [§ Cloudflare DNS — Pro and above](#cloudflare-dns--pro-and-above).
Builder and below stay on Squarespace DNS with the paste steps below. `/stack` shows
each client's live DNS host, so a Pro or Team client not yet moved reads
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
doh() { curl -s "https://dns.google/resolve?name=$1&type=$2" | jq -c '[.Status, [.Answer[]?.data]]'; }
doh <domain> TXT                      # verification + SPF
doh <domain> MX                       # 1 smtp.google.com.
doh google._domainkey.<domain> TXT    # v=DKIM1 …
doh _dmarc.<domain> TXT               # v=DMARC1 …
```

Over DoH, not local `dig`: this laptop answers port 53 itself ([moving
rules](#moving-a-domains-nameservers)).

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

- **Turning DNSSEC off is a scheduled outage of the whole domain.** Squarespace
  stops signing the moment the toggle flips, but the TLD keeps serving the DS
  until the registry drops it, so every validating resolver answers SERVFAIL:
  the site is down and inbound mail is delayed. Measured 2026-10-13:
  `commercialwelding.llc` and `mcritchie.industries` SERVFAILed on `8.8.8.8` and
  `1.1.1.1` from 11:52 to about 12:05 MDT, and Google's caches flapped until
  12:13; `turfmonster.media` did the same on 2026-09-29. Schedule it in a quiet
  window, tell Alex it is an outage, and get his explicit OK before he clicks.
- **Verify over DNS-over-HTTPS and RDAP, never local `dig`.** This laptop
  intercepts all port-53 traffic with a non-validating resolver, so `dig` and
  `curl` here showed both domains healthy for the whole outage. Read
  `https://dns.google/resolve?name=<domain>&type=A` and
  `https://cloudflare-dns.com/dns-query?name=<domain>&type=A` (header
  `accept: application/dns-json`; `Status` 2 is SERVFAIL), and the registry's
  RDAP record (`https://rdap.org/domain/<domain>`, field
  `secureDNS.delegationSigned`) for whether a DS is still published.
- **Paste the nameservers as soon as the DS clears.** An extra hour's wait buys
  nothing: a resolver still caching the DS fails the same way whichever
  nameservers answer.
- **Copy every record, subdomains included.** Compare the new zone with the old
  one record by record, including rows under subdomains such as `in.` and
  `send.in.`; a missing inbound MX drops mail silently, and dropped mail is not
  redelivered. A provider's "verified" badge is not a DNS check; `dig` against
  the new nameservers is.
- **Have Alex confirm the domain name on the registrar page before every save.**
  Registrar saves reach the registry minutes later, in order, so a save on the
  wrong domain is slow to undo.

## Cloudflare DNS — Pro and above

The bare domain becomes the app's address, `www` and any other domain redirect
at Cloudflare's edge, and every later record is an API call. Live today on
`mcritchie.studio` and `turfmonster.media` (both since 2026-09-30, records DNS
only); `/stack` tracks the rest. The edge-proxy and certificate work beyond DNS
is the separate [CDN rollout](../../../system/cdn-rollout.md); this section
moves DNS only and proxies only `www`, for its redirect, and nothing that serves the app.

The agent token `cloudflare.studio.provision` (dashboard name
`mcritchie-studio-admin`) holds Zone, Zone Settings, DNS and Dynamic URL
Redirects read/write on every zone since 2026-10-13 ([credential
inventory](../../../modules/credential-inventory.md)), so Steffon creates the
zone, reconciles its records, sets SSL and writes the `www` redirect by API.
**Alex's only clicks are at Squarespace**: DNSSEC off and the nameservers, then
DNSSEC back on once the move settles (step 7). The same step, as a launch
prerequisite, is row 0.2 of Rex's [`launch-warmup`](../../rex/sops/launch-warmup.md).

Read the token once per session, under the admin service account (as in
[`bucket-provision`](./bucket-provision.md)). Every call below sends it as a
bearer token, so an empty read must stop here:

```bash
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
CF_TOKEN=$(op read "op://studio-agents-admin/cloudflare.studio.provision/api-token")
CF_ACCOUNT=$(op read "op://studio-agents-admin/cloudflare.studio.provision/account-id")
[ -n "$CF_TOKEN" ] && [ -n "$CF_ACCOUNT" ] || { echo "cloudflare.studio.provision read empty: stop" >&2; false; }
```

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
curl -s https://rdap.org/domain/<domain> | jq '.secureDNS.delegationSigned'   # true: a DS is published
```

The `dig` lines are a record inventory only; health and DS status come from
DoH and RDAP (the [moving rules](#moving-a-domains-nameservers) say why).

Add every subdomain the client uses (`send.`, `in.`, Resend's records) to the
list; the [moving rules](#moving-a-domains-nameservers) below say why.

### 2. Create the zone and reconcile it — Steffon

Done before any outage starts, so the zone is ready the moment the DS clears:

```bash
curl -s -X POST https://api.cloudflare.com/client/v4/zones -H "Authorization: Bearer $CF_TOKEN" \
  -H "content-type: application/json" \
  --data "{\"name\":\"<domain>\",\"account\":{\"id\":\"$CF_ACCOUNT\"},\"type\":\"full\",\"jump_start\":true}" \
  | jq '{id: .result.id, ns: .result.name_servers, ok: .success}'
```

Keep the zone id and the two assigned nameservers. Read the imported records
(`GET /zones/<zone-id>/dns_records`) and make them match step 1's snapshot
**exactly**, record by record: the Google MX (`smtp.google.com`), the
`google-site-verification` TXT, SPF as ONE TXT, DKIM, DMARC, Resend's records,
and every subdomain. Every record starts **DNS only** (grey cloud), as on
`turfmonster.media`. Then the app records:

| Host | Type | Value | Proxy |
|------|------|-------|-------|
| `@` | CNAME | the Heroku DNS target (`*.herokudns.com`) from `heroku domains:add <domain> -a <app>` | DNS only — Cloudflare flattens a CNAME at the apex, which Squarespace could not do with DNSSEC on |
| `www` | CNAME | `<domain>` | **Proxied** — an edge redirect rule only runs on proxied traffic, and the redirect answers before Heroku is asked |

Then SSL **Full (strict)**, so the edge only talks to Heroku over a valid
certificate:

```bash
curl -s -X PATCH https://api.cloudflare.com/client/v4/zones/<zone-id>/settings/ssl \
  -H "Authorization: Bearer $CF_TOKEN" -H "content-type: application/json" --data '{"value":"strict"}' | jq .success
```

And the `www` → bare redirect, a single-redirect rule in phase
`http_request_dynamic_redirect` (add one rule per extra domain to forward):

```bash
curl -s -X PUT https://api.cloudflare.com/client/v4/zones/<zone-id>/rulesets/phases/http_request_dynamic_redirect/entrypoint \
  -H "Authorization: Bearer $CF_TOKEN" -H "content-type: application/json" --data '{
  "rules": [{ "description": "www to bare", "expression": "(http.host eq \"www.<domain>\")", "action": "redirect",
    "action_parameters": { "from_value": { "status_code": 301, "preserve_query_string": true,
      "target_url": { "expression": "concat(\"https://<domain>\", http.request.uri.path)" } } } }]
}' | jq '.success, (.result.rules | length)'
```

### 3. DNSSEC off, then the nameservers — Alex, then Steffon

This is the scheduled outage the [moving rules](#moving-a-domains-nameservers)
describe. Pick a quiet window and ask first, in these words: "Turning DNSSEC off
takes `<domain>` down, site and inbound mail, for roughly 15 minutes. OK to do it
now?" Go only on his explicit yes.

```not-pasteable
🙋 YOUR TURN — switch DNSSEC off (the outage starts now)
   Where:  https://account.squarespace.com/domains → <domain> → DNS → DNSSEC
   Check:  the domain name on the page is <domain> before you save
   Enter:  turn DNSSEC off; change nothing else yet
   Done when: Squarespace shows DNSSEC off
   Then tell me "done" — and do NOT paste nameservers until I say so.
```

Steffon polls RDAP until `secureDNS.delegationSigned` reads `false` (minutes
to an hour), then asks for the nameservers at once:

```not-pasteable
🙋 YOUR TURN — move the nameservers (DNSSEC already off)
   Where:  https://account.squarespace.com/domains → <domain> → DNS → Nameservers
   Check:  the domain name on the page is <domain> before you save
   Enter:  Use custom nameservers: the two Cloudflare gave you, exactly
   Done when: Squarespace shows the two Cloudflare nameservers
   Then tell me "done".
```

Steffon watches DoH (`dns.google` and `cloudflare-dns.com`) until both answer
`Status` 0 with the Cloudflare nameservers; that ends the outage.

### 4. Confirm the zone is active — Steffon

```bash
curl -s https://api.cloudflare.com/client/v4/zones/<zone-id> -H "Authorization: Bearer $CF_TOKEN" | jq -r .result.status   # active
```

Cloudflare marks the zone `active` once it sees its own nameservers at the
registry; the redirect rule and SSL setting from step 2 apply from then.

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

Over DoH, since local port-53 answers cannot be trusted here:

```bash
for t in NS MX TXT; do curl -s "https://dns.google/resolve?name=<domain>&type=$t" | jq -c '[.Status, [.Answer[]?.data]]'; done
curl -s -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=<domain>&type=A" | jq -c '[.Status, [.Answer[]?.data]]'
```

Then the record-by-record comparison against step 1, also over DoH (the
interception catches a `dig @<nameserver>` too):

```bash
doh() { curl -s "https://dns.google/resolve?name=$1&type=$2" | jq -c '[.Status, [.Answer[]?.data]]'; }
doh <domain> NS                       # [0, *.ns.cloudflare.com]
doh <domain> MX                       # 1 smtp.google.com. (unchanged)
doh <domain> TXT                      # verification + the one SPF (unchanged)
doh google._domainkey.<domain> TXT    # unchanged
doh in.<domain> MX                    # unchanged (a past Cloudflare move dropped in.* MX)
doh send.<domain> MX                  # unchanged; plus every subdomain row from step 1
curl -sS -o /dev/null -w "%{http_code}\n" https://<domain>/up                         # 200
curl -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://www.<domain>/x?y=1"   # 301 https://<domain>/x?y=1
```

The two `curl` lines prove the app and the redirect, not DNS health: they
resolve through the local interception like everything else.

Green when every mail and verification record matches step 1's snapshot, the
bare domain answers `200` over HTTPS, and `www` answers `301` to the bare
domain with its path. `/stack` then shows the client **On Cloudflare**.

Record: `bin/task update <launch-task> --checks "[control] domain-dns: <domain> on Cloudflare, mail records unchanged, www 301s to the bare domain"`.

### 7. DNSSEC back on, from Cloudflare — Steffon, then Alex

After the move has settled (a day of green step 6), sign the zone at
Cloudflare and publish its DS at the registrar. No outage this time: the DS
goes up only after the zone is already signing.

```bash
curl -s -X PATCH https://api.cloudflare.com/client/v4/zones/<zone-id>/dnssec \
  -H "Authorization: Bearer $CF_TOKEN" -H "content-type: application/json" --data '{"status":"active"}' \
  | jq '.result | {status, key_tag, algorithm, digest_type, digest}'
```

```not-pasteable
🙋 YOUR TURN — publish the DS record
   Where:  https://account.squarespace.com/domains → <domain> → DNS → DNSSEC
   Check:  the domain name on the page is <domain> before you save
   Enter:  Key tag <key_tag> · Algorithm <algorithm> · Digest type <digest_type> · Digest <digest>
   Done when: Squarespace shows the DS record saved
   Then tell me "done".
```

Green when RDAP reads `secureDNS.delegationSigned: true`, the zone's DNSSEC
status reads `active`, and `dns.google/resolve` answers `Status` 0 with
`"AD": true`.

