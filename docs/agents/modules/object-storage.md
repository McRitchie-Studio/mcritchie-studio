# Object Storage — R2 buckets, tokens, and conventions

## Status: Active

Steffon owns this module. Alex approved the S3 rules on 2026-09-01 and the move
to **Cloudflare R2** on 2026-09-26 (asset-library plan, Wave 1), and handed
maintenance to Steffon's role: rule changes ride normal doc tasks under his
name, and `bucket-provision`
([`../agents/steffon/sops/bucket-provision.md`](../agents/steffon/sops/bucket-provision.md))
is the act that applies them to a new app.

**Where storage lives now.** Every app's object storage is an R2 bucket pair in
**McRitchie Studio's Cloudflare account**. Apps inherit that account; none holds
its own. AWS S3 is **legacy**: the pairs below still serve the live apps until
each app's Wave 2 cutover task moves its objects and config, and the whole AWS
section at the end of this page retires with the last of them (Wave 7). Why R2:
Alex is leaving AWS for a simpler operator experience, not for cost; R2 speaks
the S3 API, so Active Storage and `Studio::S3` move by endpoint and key, not by
rewrite. The whole plan (tiers, cutover recipe, asset catalog, AWS exit) is
[`../system/asset-library-plan.md`](../system/asset-library-plan.md).

## R2 — the rules

| Rule | Standard |
|---|---|
| Account | McRitchie Studio's Cloudflare account, for every app. The provisioning credential is `cloudflare.studio.provision` |
| Buckets per app | `<app>-dev` + `<app>-production`, the same names the S3 pairs used; provisioning is opt-in at app creation |
| Location | location hint `enam` (eastern North America, nearest Heroku's US region). R2's region string is `auto` |
| Endpoint | `https://<account-id>.r2.cloudflarestorage.com`, stored as the `endpoint` field of each `r2.<app>` item |
| Write routing | prod app → production bucket; **QA and local → dev bucket** |
| Read routing | QA/local may read prod, enforced by the dev token's grant, never by app discipline |
| App credentials | two bucket-scoped Cloudflare tokens per app: `r2-<app>-prod` (Bucket Item Write on production) and `r2-<app>-dev` (Bucket Item Write on dev + **Bucket Item Read** on production). Their S3 keys: access key id = token id, secret = SHA-256 of the token value |
| Public access | private by default; R2 has no public-access block because nothing is public until a custom domain or `r2.dev` URL is attached. Public serving is a per-bucket decision in the app's cutover task |
| Private assets | served through app auth via presigned URLs, which R2 supports on the S3 endpoint |
| Code discipline | writes fail loudly. Never wrap an upload in a rescue that returns success |

## R2 — gaps against the S3 rules

These are measured against Cloudflare's S3-compatibility page, not assumed.

- **No object versioning.** `PutBucketVersioning` is unimplemented, so the S3
  rule "production versioned" has no R2 equivalent. An errant overwrite or
  delete on a production bucket is NOT recoverable from the bucket itself.
  The undo is Steffon's [`r2-backup`](../agents/steffon/sops/r2-backup.md)
  SOP: a per-app `<app>-backup` bucket holding a mirror of production plus a
  30-day archive of everything overwritten or deleted, collected by R2
  lifecycle rules. Its nightly run is not automated yet. On a production
  bucket without backup enabled, a destructive bulk operation needs Alex's
  explicit yes; with it enabled, run a backup first and read its receipt.
- **No tags, ACLs, or bucket policies.** Cost lines come from bucket names, and
  every grant lives on a token.
- **Custom domains need zone DNS.** `cloudflare.studio.provision` carries no
  zone DNS permission, so attaching `assets.<domain>` to a bucket is a
  dashboard step (**R2 → bucket → Settings → Custom Domains**) in the app's
  cutover task.

## R2 — credential tiers

| Tier | Identity | Holds | Store |
|---|---|---|---|
| 1 | Alex's Cloudflare login | Alex only | his private vault |
| 2 | `cloudflare.studio.provision` (Cloudflare token name `mcritchie-studio-admin`) | Steffon's provisioning lane: Workers R2 Storage read/write, Account API Tokens read/write (mints the per-app tokens), Account DNS Settings | `studio-agents-admin` (admin op lane only) |
| 4b | `r2-<app>-backup` | reads `<app>-production`, writes `<app>-backup`; no app key can see the backup bucket | fields `access-key-id-backup` / `secret-access-key-backup` in `r2.<app>` |
| 4 | `r2-<app>-prod` / `r2-<app>-dev` | one app's buckets, exactly | 1Password `r2.<app>` in `studio-agents`; Heroku config vars once the app cuts over |

Tier 3 (a fleet-wide agent key for object surgery) has no R2 equivalent yet, as
it had none on S3. A credential belongs to exactly one kind of principal: apps
never borrow agent keys; agents never borrow app keys.

## R2 — fleet census, 2026-09-26

Provisioned and verified by `bucket-provision` on 2026-09-26: every pair passed
the positive probes and the three negative ones (prod key refused on dev, dev
key refused a production write and a production delete). All buckets are
private and empty; no app reads them yet.

| App | Buckets | 1Password | Serving | Backup (`r2-backup`) |
|---|---|---|---|---|
| `mcritchie-studio` | `mcritchie-studio-{dev,production}` | `r2.mcritchie-studio` | not yet (Wave 2) | not enabled |
| `turf-monster` | `turf-monster-{dev,production}` | `r2.turf-monster` | not yet (Wave 2) | not enabled |
| `mcritchie-industries` | `mcritchie-industries-{dev,production}` | `r2.mcritchie-industries` | not yet (Wave 2) | not enabled |
| `commercial-welding` | `commercial-welding-{dev,production}` | `r2.commercial-welding` | not yet (Wave 2) | not enabled |
| `moms-app` | `moms-app-{dev,production}` | `r2.moms-app` | not yet (Wave 2) | enabled 2026-09-26, `moms-app-backup`; drill passed |

Re-derive before trusting: `GET /accounts/<id>/r2/buckets` with the tier-2
token lists the pairs, and the SOP's verify script re-runs the probes. A census
is only true for the day it was taken.

---

# Legacy — AWS S3 (retires app by app in Wave 2, wholly in Wave 7)

Everything below describes the S3 buckets the live apps still serve from. Do
not provision new S3 buckets.

## S3 — the rules

| Rule | Standard |
|---|---|
| Buckets per app | `<app>-dev` + `<app>-production`; provisioning is opt-in at app creation — a silly little app can decline |
| Region | `us-east-2` — the fleet's home; do not scatter |
| Write routing | prod app → production bucket; **QA and local → dev bucket** |
| Read routing | QA/local may read prod — enforced by IAM, never by app discipline |
| App credentials | two IAM users per app under path `/mcr/`: `mcr-<app>-prod` (RW its production bucket) and `mcr-<app>-dev` (RW its dev bucket + **read-only** its production bucket). QA runs the dev credential |
| Public access | private by default: Block Public Access all-on, no bucket policy. Public serving is an explicit, documented exception (see **S3 — legacy posture**) |
| Private assets | served through app auth via presigned URLs (~15-min GET). Any key with `s3:GetObject` can presign; no extra permission exists |
| Versioning | ON for production buckets (an errant overwrite or delete is recoverable); dev unversioned |
| Lifecycle | **design pending** — dev buckets carry seed assets apps still serve, so a blanket dev expiry would break local stacks. Do not add lifecycle rules ad hoc |
| Encryption | SSE-S3 (AES256, the account default). Buckets are `bucket-owner-enforced`: ACLs are disabled, `put_object(acl: …)` raises — grant reads through bucket policy or presigned URLs, never per-object ACLs |
| Tags | `app`, `env`, `entity` on every bucket — the cost lines |
| Code discipline | S3 writes fail loudly. Never wrap an upload in a rescue that returns success — a QA lane once shared prod's bucket with no credentials and its writes failed silently for weeks |
| URL style | path-style (`https://s3.us-east-2.amazonaws.com/<bucket>/<key>`); the virtual-hosted host trips Chrome's lookalike-domain interstitial against `mcritchie.studio` |

## S3 — the credential tiers

| Tier | Identity | Holds | Store |
|---|---|---|---|
| 1 | `alex-admin` / root | Alex only | his private vault |
| 2 | `studio-agents-admin` | Steffon's provisioning lane: `s3:*`, mint/rotate `/mcr/*` users, account read-only | item `AWS`, vault `studio-agents-admin` (admin op lane only) |
| 3 | `agent-studio` | day-to-day agent object surgery across the fleet; no IAM, no bucket create/delete | **design pending** — nothing mints it yet, `bucket-provision` included; until it exists, use tier 2 or the app's tier-4 key |
| 4 | `mcr-<app>-prod` / `mcr-<app>-dev` | one app's buckets, exactly | Heroku config vars + 1Password record |

A credential belongs to exactly one kind of principal. Apps never borrow agent
keys; agents never borrow app keys.

Reading tier 2 (the only lane this module's procedures need):

```bash
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
export AWS_ACCESS_KEY_ID=$(op item get AWS --vault studio-agents-admin --fields label=access-key --reveal)
export AWS_SECRET_ACCESS_KEY=$(op item get AWS --vault studio-agents-admin --fields label=secret-access-key --reveal)
export AWS_DEFAULT_REGION=us-east-2
```

The ordinary agent token cannot list the `studio-agents-admin` vault — that
invisibility is the design
([`credential-inventory.md`](credential-inventory.md)). The admin service
account has read AND write on `studio-agents*` since 2026-09-02, so `op item
edit` succeeds and a refusal is a symptom (`credential-filing` §4). This line
said read-only until 2026-09-26.

**Guards, stated honestly.** `studio-agents-admin` sits outside the `/mcr/` IAM path,
so it cannot edit its own policy — policy changes are an operator console
paste. It CAN write arbitrary inline policies onto the `/mcr/*` users it
mints, so a compromised tier 2 could mint an over-privileged user; the sealed
fix is an IAM permissions boundary, filed as OPSEC backlog, not ceremony.

## S3 — fleet census, 2026-09-01, post-remediation

| Bucket | Region | Public read | Versioned | Notes |
|---|---|---|---|---|
| `mcritchie-studio-production` | us-east-2 | **yes — legacy** | yes | Active Storage + public assets |
| `mcritchie-studio-dev` | us-east-2 | **yes — legacy** | no | has `archive-after-90-days` lifecycle |
| `turf-monster-production` | us-east-2 | **yes — legacy** | yes | |
| `turf-monster-dev` | us-east-2 | **yes — legacy** | no | |
| `mcritchie-industries-production` | us-east-2 | no (flipped 2026-09-01) | yes | knowledge-layer destination; was world-readable while empty |
| `mcritchie-industries-dev` | us-east-2 | no (flipped 2026-09-01) | no | |
| `commercial-welding-production` | us-east-2 | no | yes | recreated 2026-09-01 from us-east-1 |
| `commercial-welding-dev` | us-east-2 | no | no | recreated 2026-09-01 from us-east-1 |
| `moms-app-production` | us-east-2 | no | yes | was the fleet's one private bucket all along |

Re-derive before trusting: `aws s3api get-bucket-policy` /
`get-public-access-block` / `get-bucket-versioning` per bucket — a census is
only true for the day it was taken.

## S3 — legacy posture

- **Shared app identity.** One IAM user, `mcritchie-s3` (item `agent.aws`),
  still backs Active Storage for every deployed app. The per-app tier-4 users
  are the successor; migration is ladder work, one app per task, coordinated
  with that app's config vars. Blast radius and rotation choreography:
  [`credential-inventory.md`](credential-inventory.md) **Shared AWS identity**.
- **Public-read buckets.** The four studio/turf buckets keep
  `PublicReadGetObject` because deployed apps serve raw object URLs from them.
  Removing it is app work (CDN or public-prefix migration — see
  [`../system/cdn-rollout.md`](../system/cdn-rollout.md)), not a console flip;
  on those buckets `public: false` in `storage.yml` is NOT a privacy control.
- **Industries QA — Active Storage CUT OVER 2026-09-02; `Studio::S3` was NOT.**
  Industries became the first app on tier-4 credentials:
  `mcr-mcritchie-industries-{prod,dev}` were minted under `/mcr/` by
  `bucket-provision`'s first live run, the routing law was proven by refusal
  (the dev key's write to the production bucket was rejected by IAM), and both
  Heroku apps carry their vars (prod key on `mcritchie-industries`, dev key on
  `mcritchie-industries-qa`). `QA_ENV=true` now ships on the QA app and is
  declared in `config/qa_environments.yml`, so `storage.yml` resolves
  `mcritchie-industries-dev` (`/tasks/industries-qa-bucket-cutover`) — **but
  that marker fixes only ONE of the app's TWO S3 writers.** Measured on a QA
  dyno 2026-09-02, post-cutover: `ActiveStorage_bucket` =
  `mcritchie-industries-dev`, `Studio::S3.bucket` =
  `mcritchie-industries-production`. The engine has since been fixed:
  `Studio::S3`'s private `environment` now returns `dev` when
  `EnvironmentBanner.qa_environment?` holds, so both writers agree on a QA
  dyno (read in `studio-engine/lib/studio/s3.rb` on 2026-09-26; re-measure on
  a dyno before relying on it for an app pinned to an older engine). The
  1Password record (`agent.mcritchie-industries.aws`, `industries-agents`
  vault) is owed by a write-capable lane — values live in Heroku config until
  it lands.
