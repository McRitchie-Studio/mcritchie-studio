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
its own. AWS S3 is **retired**: the hub, Turf Monster, Industries and
`moms-app` have served from R2 alone since 2026-10-03 (`commercial-welding` has
not cut over), and the AWS section at the end of this page is history. **The
AWS side was retired on 2026-10-10**: the app IAM users (`mcritchie-s3`,
`mcritchie-ses`, `mcr-mcritchie-industries-prod` and `-dev`) and their keys
deleted, every SES identity deleted, the S3 desk bucket gone, no `AWS_*`
variable left on Heroku. The hub's code followed in task
`hub-storage-runs-r2-only`: it has no S3 stage, no mirror stage and no SES path
left to select (see **The hub runs R2 only** below). Why R2:
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
| Read routing | QA/local may read prod, enforced by the dev token's grant, never by app discipline. Measured 2026-10-10 through the Cloudflare API: the QA/dev tokens for the hub, Turf and Industries each hold Bucket Item Read on `<app>-production` and Bucket Item Write on `<app>-dev` only |
| Seed assets | live in the **production** bucket. Non-production seed data references them at the production asset host; only a new non-production upload goes to the dev bucket. See [Seed assets](#seed-assets) |
| App credentials | two bucket-scoped Cloudflare tokens per app: `r2-<app>-prod` (Bucket Item Write on production) and `r2-<app>-dev` (Bucket Item Write on dev + **Bucket Item Read** on production). Their S3 keys: access key id = token id, secret = SHA-256 of the token value |
| Public access | private by default; R2 has no public-access block because nothing is public until a custom domain or `r2.dev` URL is attached. Public serving is a per-bucket decision in the app's cutover task |
| Private assets | served through app auth via presigned URLs, which R2 supports on the S3 endpoint |
| Code discipline | writes fail loudly. Never wrap an upload in a rescue that returns success |
| Active Storage on R2 | every R2 service in `config/storage.yml` sets `request_checksum_calculation: when_required` and `response_checksum_validation: when_required`. Active Storage sends Content-MD5 and aws-sdk-s3 adds a CRC32, and R2 refuses the pair. A `Studio::S3` probe sends no Content-MD5, so its success proves nothing about Active Storage |
| Deletes go to trash | an app's R2 Active Storage services name `service: StudioTrashS3` (studio-engine), not `S3`. Purging or replacing an attachment then copies the object to `trash/<utc date>/<epoch ms>/<key>` in the same bucket and only then deletes the original; a failed copy raises and deletes nothing. `Studio::S3.delete` does the same. The bucket's `expire-trash-3d` lifecycle rule removes the trash copy after three days; until then `rake studio:trash:restore[TRASH_KEY]` puts the bytes back. The service refuses to delete from a `*-production` bucket unless the process is real production, so QA and local services must name the dev bucket. The hub adopted it on 2026-10-10 |

## The hub runs R2 only

Since task `hub-storage-runs-r2-only` (2026-10-10) the hub's storage code has
one backend. `config/initializers/00_storage_backend.rb` holds the rules and
`test/integration/storage_boot_matrix_test.rb` boots real processes to hold them.

| Setting | Rule |
|---|---|
| `ACTIVE_STORAGE_BACKEND`, `STUDIO_S3_BACKEND` | optional. Unset means R2; `r2` is accepted so the live config stays valid. A retired value (`s3`, `mirror_to_r2`, `mirror_to_s3`) or a typo **raises at boot in every environment**, naming the variable |
| `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_PUBLIC_URL` | **required in production and QA** (both boot `RAILS_ENV=production`): a missing one raises from the initializer, naming it. That fails Heroku's release phase, where a bad storage config used to pass and then crash-loop web and worker |
| Test, CI, a keyless local desk | boot without any of them. The services are still R2-shaped, built on a placeholder: the reserved host `r2-not-configured.invalid` (never resolves) and placeholder keys. Nothing can reach AWS or a real bucket, and the first real call fails naming that host. Code that must refuse up front asks `StorageBackend.configured?` |
| Active Storage services | `amazon` (production, QA) and `amazon_dev` (local) keep their names, because blob rows record them. Both are `StudioTrashS3` on R2. QA's `amazon` resolves the dev bucket through `QA_ENV` |
| `DeskCapture` | R2 only, with its own keys (`DESK_CAPTURE_R2_ENDPOINT`, `DESK_CAPTURE_R2_ACCESS_KEY_ID`, `DESK_CAPTURE_R2_SECRET_ACCESS_KEY`). `DESK_CAPTURE_BACKEND` is optional and accepts only `r2`; any other value raises at the first read or write. Nothing is checked at boot, because QA and local desks hold no desk keys. The S3 half, `DESK_CAPTURE_REGION` and the SES poll job (`DeskCapturePollJob`) are deleted |

**Removing a storage variable on Heroku now stops the next boot.** Unset an
`R2_*` variable only together with a deploy that no longer reads it.

## Seed assets

An image a seed file names (a Pokémon sprite) is uploaded
once, to the production bucket, and every environment's seed data references it
at the production asset host (`https://assets.mcritchie.studio/...`). A QA app
or a laptop does not upload its own copy into the dev bucket. The dev bucket
holds only what a non-production process newly made: a test upload, or a demo
file a local seed renders (`db/seeds/data/tiled_video_files.rb`).

What holds it in the hub:

- **The committed URLs.** `db/seeds/data/pokemon.json` and `e2e/seed.rb` carry
  absolute production URLs. `lib/tasks/pokemon.rake` writes them from a constant
  (`POKEMON_ASSET_BASE`), not from the running process's storage adapter, whose
  public base on a laptop is the dev bucket's domain.
  `test/lib/pokemon_seed_asset_urls_test.rb` requires every URL in the file to
  be on the production host and no seed file to name a dev bucket's host.
- **No non-production write to production.** The dev token cannot write the
  production bucket, `Studio::S3` refuses a delete from a `*-production` bucket
  off production, and the Pokémon upload tasks, which pass their own bucket
  name, refuse the production bucket off production before any upload
  (`pokemon_upload_bucket!`).

**Not yet conforming: cached headshots.** `nfl:players_seed`,
`nfl:upload_headshots` and `nfl:upload_coach_headshots` fetch each headshot from
ESPN and upload its variants to the bucket of the process that runs them, so a
laptop or QA run puts copies in the dev bucket under the keys production
already holds. An `ImageCache` row stores a key, and `ImageCache#url`
(studio-engine) joins it to the process's one public base, so a row cannot say
"this object is production's". Referencing production's copies needs that in
the engine first; until then `WITH_NFL_HEADSHOTS=1` on a rebuild is the path
that makes the copies, and it is opt-in.

## R2 — gaps against the S3 rules

These are measured against Cloudflare's S3-compatibility page, not assumed.

- **No object versioning.** `PutBucketVersioning` is unimplemented, so the S3
  rule "production versioned" has no R2 equivalent. An errant overwrite or
  delete on a production bucket is NOT recoverable from the bucket itself.
  The undo is Steffon's [`r2-backup`](../agents/steffon/sops/r2-backup.md)
  SOP: a per-app `<app>-backup` bucket holding a mirror of production plus a
  30-day archive of everything overwritten or deleted, collected by R2
  lifecycle rules. Its nightly run is `.github/workflows/r2-backup.yml`, for the
  apps in its matrix. On a production
  bucket without backup enabled, a destructive bulk operation needs Alex's
  explicit yes; with it enabled, run a backup first and read its receipt.
- **No tags, ACLs, or bucket policies.** Cost lines come from bucket names, and
  every grant lives on a token.
- **Custom domains need the domain on Cloudflare.** R2 attaches
  `assets.<domain>` only to a domain whose DNS Cloudflare serves in this
  account. Since 2026-09-30 `mcritchie.studio` and `turfmonster.media` both
  are (zones Active, every app record DNS only, so traffic still reaches
  Heroku directly; R2 proxies the `assets.` CNAME it manages), and `assets.mcritchie.studio` / `assets.turfmonster.media` serve
  the two production buckets. `cloudflare.studio.provision` can do the whole
  attach by API: it listed both zones and created both custom domains
  (`POST /accounts/<id>/r2/buckets/<bucket>/domains/custom` with the zone id),
  measured 2026-09-30, with no Zone Read: its policies, read back that day,
  hold DNS read/write and none. A new certificate took hours, not minutes: attached
  00:25 MDT, first 200 at 08:09.

## R2 — credential tiers

| Tier | Identity | Holds | Store |
|---|---|---|---|
| 1 | Alex's Cloudflare login | Alex only | his private vault |
| 2 | `cloudflare.studio.provision` (Cloudflare token name `mcritchie-studio-admin`) | Steffon's provisioning lane: Workers R2 Storage read/write, Account API Tokens read/write (mints the per-app tokens), Account DNS Settings, and (since the evening of 2026-09-26) DNS read/write on every domain in the account | `studio-agents-admin` (admin op lane only) |
| 4 | `r2-<app>-prod` / `r2-<app>-dev` | one app's buckets, exactly | 1Password `r2.<app>` in `studio-agents`; Heroku config vars once the app cuts over |
| 4b | `r2-<app>-backup` | reads `<app>-production`, writes `<app>-backup`; no app key can see the backup bucket | fields `access-key-id-backup` / `secret-access-key-backup` in `r2.<app>` |

Tier 3 (a fleet-wide agent key for object surgery) has no R2 equivalent yet, as
it had none on S3. A credential belongs to exactly one kind of principal: apps
never borrow agent keys; agents never borrow app keys.

## R2 — fleet census, 2026-09-26

Provisioned and verified by `bucket-provision` on 2026-09-26: every pair passed
the positive probes and the three negative ones (prod key refused on dev, dev
key refused a production write and a production delete). All buckets are
private. They were empty at provisioning. Since 2026-10-03
every app but `commercial-welding` serves from its production bucket alone.
Each enabled `<app>-backup` holds its mirror, drill receipts and archives
(archives and receipts expire under its lifecycle rules). Rows carry their own
dates where they changed after the census.

| App | Buckets | 1Password | Serving | Backup (`r2-backup`) |
|---|---|---|---|---|
| `mcritchie-studio` | `mcritchie-studio-{dev,production}` | `r2.mcritchie-studio` | R2 alone since 2026-10-03 (Active Storage `r2`, v543; `Studio::S3` on R2 since 2026-09-30); `assets.mcritchie.studio` serves production, `assets-dev.mcritchie.studio` the dev bucket; QA (`mcritchie-studio-qa`) and local dev on the dev bucket | enabled 2026-10-03, `mcritchie-studio-backup`; drill passed 2026-10-03; nightly via `.github/workflows/r2-backup.yml` |
| `mcritchie-studio` (`DeskCapture`) | `mcritchie-studio-desk`, one private bucket, no pair (added 2026-09-29) | `r2.mcritchie-studio-desk` | R2 since 2026-10-01 (`DESK_CAPTURE_BACKEND=r2`, v542), and R2 only since 2026-10-10: the S3 desk bucket and the SES fallback that read it are gone | enabled 2026-10-10, `mcritchie-studio-desk-backup` (token `r2-mcritchie-studio-desk-backup`, fields in `r2.mcritchie-studio-desk`, repo secrets `R2_BACKUP_MCRITCHIE_STUDIO_DESK_*`); isolation probes passed; the first run mirrored 104 of 104 objects; nightly via `.github/workflows/r2-backup.yml` |
| `turf-monster` | `turf-monster-{dev,production}` | `r2.turf-monster` | R2 alone since 2026-10-03 (Active Storage `r2`, v305; `Studio::S3` on R2 since 2026-09-30); `assets.turfmonster.media` serves production, `assets-dev.turfmonster.media` the dev bucket; QA and local dev on the dev bucket | enabled 2026-10-03, `turf-monster-backup`; drill passed 2026-10-03; nightly via `.github/workflows/r2-backup.yml` |
| `mcritchie-industries` | `mcritchie-industries-{dev,production}` | `r2.mcritchie-industries` | R2 alone since 2026-10-03 (Active Storage `r2`, v54; knowledge docs on R2 since 2026-09-28); QA on the dev bucket | enabled 2026-09-28, `mcritchie-industries-backup`; drill passed on live data; nightly via `.github/workflows/r2-backup.yml` |
| `commercial-welding` | `commercial-welding-{dev,production}` | `r2.commercial-welding` | not yet (Wave 2) | not enabled |
| `moms-app` | `moms-app-{dev,production}` | `r2.moms-app` | R2 alone since 2026-10-03 (Active Storage `r2`, v25) | enabled 2026-09-26, `moms-app-backup`; drill passed; nightly via `.github/workflows/r2-backup.yml` |

Re-derive before trusting: `GET /accounts/<id>/r2/buckets` with the tier-2
token lists the pairs, and the SOP's verify script re-runs the probes. A census
is only true for the day it was taken.

---

# Legacy — AWS S3 (retired 2026-10-10)

Everything below is the pre-R2 posture, kept for history. The identities it
names (`mcritchie-s3`, the `/mcr/` users) no longer exist; the admin item `AWS`
in `studio-agents-admin` is the one AWS credential kept, as a read-only
foothold. Nothing below is a procedure to run: no cut-over app has
used S3 since 2026-10-03, and the cutover session reports the production buckets
cleared that night (versioned; noncurrent versions expire after 30 days). The
IAM users and keys named below were deleted on 2026-10-10, so the commands in
this section no longer authenticate. Do not provision new S3 buckets.

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
