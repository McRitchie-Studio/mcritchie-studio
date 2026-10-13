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
  `secureDNS.delegationSigned`) for whether a DS is still published. rdap.org
  answers 302 to the registry's own RDAP server, so follow it (`curl -sL`); a
  bare `curl -s` hands `jq` an empty body and prints nothing.
- **Paste the nameservers as soon as the DS clears.** An extra hour's wait buys
  nothing: a resolver still caching the DS fails the same way whichever
  nameservers answer.
- **Copy every record, subdomains included.** Compare the new zone with the old
  one record by record, including rows under subdomains such as `in.` and
  `send.in.`; a missing inbound MX drops mail silently, and dropped mail is not
  redelivered. A provider's "verified" badge is not a DNS check; a DoH read
  from both resolvers is.
- **Finalize six hours after the registry change, not sooner.** Resolvers keep
  the OLD nameservers cached for up to the TLD's NS TTL (21600 s), and the old
  zone keeps answering them, so the `www` redirect and `APP_HOST` wait. A mixed
  cache otherwise loops (new `www` → bare, old bare → registrar forwarding →
  `www`) or lands on a bare domain the old zone lacks. Measured 2026-10-13, and
  `bin/domain-cutover finalize` enforces it.
- **Have Alex confirm the domain name on the registrar page before every save.**
  Registrar saves reach the registry minutes later, in order, so a save on the
  wrong domain is slow to undo.

## Cloudflare DNS — Pro and above

The bare domain becomes the app's address, `www` redirects to it at
Cloudflare's edge, and every later record is an API call. Live on
`mcritchie.studio` and `turfmonster.media` (2026-09-30), `commercialwelding.llc`
and `mcritchie.industries` (2026-10-13); `/stack` tracks the rest. This moves DNS
only and proxies only `www`, for its redirect; the edge proxy beyond that is the
separate [CDN rollout](../../../system/cdn-rollout.md).

One command runs the move, by phase: `bin/domain-cutover <app> <domain>
plan|verify|finalize|workspace|status`. Its state sits in the hub's
`tmp/domain-cutover/<domain>.json`, so `status` answers from any shell. Every
write is read back. `--dry-run` prints each write and makes none. It reads DNS
only over DoH and RDAP, for the reason in the [moving
rules](#moving-a-domains-nameservers). It reads its credentials from 1Password by
name and prints none: `cloudflare.studio.provision` on the admin lane, which
holds Zone, Zone Settings, DNS and Dynamic URL Redirects read/write on every zone
([credential inventory](../../../modules/credential-inventory.md)), and
`HEROKU_API_KEY` or `heroku.studio.agents`.

```bash
source ~/.zprofile.admin                # the admin lane the Cloudflare read needs
export OP_ADMIN_SERVICE_ACCOUNT_TOKEN
bin/domain-cutover <app> <domain> status
```

**The only human steps are registrar clicks**, Alex's for our domains, the
client's for theirs: DNSSEC off when a DS is published, then the nameservers.
`plan` prints them for the domain's registrar (Squarespace, GoDaddy, Namecheap,
Porkbun, or the no-click Cloudflare-hosted variant), addressed with `--to alex`
or `--to client`.

**Client-owned domains.** The client buys and owns the domain at any registrar
except Cloudflare Registrar: that would put the zone in the client's own
Cloudflare account, which our token cannot reach (`plan` refuses such a domain).
Our own entities may buy on Cloudflare Registrar; theirs is the no-click
variant. Buying for our own entities is [`domain-purchase`](./domain-purchase.md).

### 1. Plan — Steffon

```bash
bin/domain-cutover <app> <domain> plan --dry-run      # read it; then without --dry-run
bin/domain-cutover <app> <domain> plan --to client    # a client's domain
```

`plan` reads the registrar and the DS over RDAP and snapshots every record over
DoH (pass `--name <sub>` for any subdomain the client uses beyond the defaults:
`www`, `google._domainkey`, `_dmarc`, `resend._domainkey`, `send`, `in`,
`send.in`, `mail`, `qa`). It adds the bare domain to Heroku and creates the zone.
It then copies every record exactly and DNS only, re-listing first because the
import can come back empty. A record the import found and the snapshot did not
is kept and named. It adds `@` CNAME to the Heroku target (DNS only, flattened)
and `www` CNAME to the domain (proxied), sets SSL Full (strict), and writes the
`www` → bare 301 **disabled**. It refuses during a SERVFAIL. Last, it prints the
registrar guide.

### 2. The registrar — Alex or the client

Hand over the guide `plan` printed. When a DS is published, its first step is
**DNSSEC off, a scheduled outage**: ask first ("Turning DNSSEC off takes
`<domain>` down, site and inbound mail, for 15 minutes to an hour (up to a
day on a .com). OK to do it now?") and go only on an explicit yes. The 15
minutes is the measured best case; the bound is the registry dropping the DS
plus the DS TTL a validating resolver cached (3600s on .llc and .org, 86400s on
.com). Then run `verify` until it reads `no DS
published: clear`, and have them paste the nameservers **at once**.

### 3. Verify — Steffon

```bash
bin/domain-cutover <app> <domain> verify    # exit 0 only when all green
```

It checks the registry's nameservers and DS (RDAP), triggers Cloudflare's
activation check once the registry shows its nameservers, and confirms both DoH
resolvers answer every record the zone holds (plan already proved the zone holds
the snapshot). It asks Heroku for the
bare domain's certificate only once that domain resolves publicly. The first
time it sees Cloudflare's nameservers at the registry, it starts finalize's
six-hour clock; a verify that finds the registry back on other nameservers
resets it, and finalize re-reads the registry before it writes.

### 4. Finalize, six hours later — Steffon

```bash
bin/domain-cutover <app> <domain> status      # "finalize allowed at …"
bin/domain-cutover <app> <domain> finalize
```

It refuses until six hours after that first sighting, and until Heroku ACM reads
`cert issued`. Resolvers cache the old nameservers for up to 6h (TTL 21600) and
the old zone keeps answering them. A redirect or an `APP_HOST` move inside that
window lets a mixed cache loop (new `www` → bare, old bare → registrar forwarding
→ `www`) or land on a bare domain the old zone lacks. Then it sets `APP_HOST`
(and adds the bare and `www` hosts to `APP_HOSTS` where the app keeps one),
re-reading the config vars until they settle. It enables the redirect, reads it
back and re-verifies. `APP_HOST` also drives mailer links and the Google callback
([`deployment.md`](../../../modules/deployment.md)); a host change there may owe
a new authorized redirect URI. Retire the registrar's old forwarding only after
this is green.

Record: `bin/task update <launch-task> --checks "[control] domain-dns: <domain> on Cloudflare, records match the snapshot, www 301s to the bare domain"`.

### 5. Workspace mail — Steffon

```bash
bin/domain-cutover <app> <domain> workspace --verification <google-site-verification=…> \
  [--rua mailto:dmarc@<domain>] [--dkim "v=DKIM1; k=rsa; p=…"]
```

It writes the verification TXT, Google's MX set (1 `aspmx.l.google.com`; 5
`alt1`/`alt2`; 10 `alt3`/`alt4.aspmx.l.google.com`), ONE SPF TXT merged with any
include already there, and DMARC at `p=none` (`rua` defaults to
`mailto:team@<domain>`). Without `--dkim` it prints the Google Admin one-click
prompt (step 2 above); rerun with the value to publish `google._domainkey`. It
refuses to overwrite a different MX, DMARC or DKIM unless given `--replace-mail`.
A domain already on Google's single `smtp.google.com` MX is left alone.

### 6. DNSSEC back on, from Cloudflare — Steffon, then Alex

After the move has settled (a day of green `verify`), sign the zone at
Cloudflare and publish its DS at the registrar. No outage this time: the DS
goes up only after the zone is already signing. The command does not do this
step; the zone id is in `tmp/domain-cutover/<domain>.json`.

```bash
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
CF_TOKEN=$(op read "op://studio-agents-admin/cloudflare.studio.provision/api-token")
[ -n "$CF_TOKEN" ] || { echo "cloudflare.studio.provision read empty: stop" >&2; false; }
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

