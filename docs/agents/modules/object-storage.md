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
`moms-app` have served from R2 alone since 2026-10-03, and since 2026-10-10
their code, in production and QA, has no S3 or mirror stage left
(`hub-storage-runs-r2-only`, `turf-storage-runs-r2-only`,
`industries-storage-runs-r2-only`, `moms-app-storage-runs-r2-only`).
`commercial-welding` has no app and had nothing to move. **The AWS side was
retired on 2026-10-10**; the little that remains is listed in
[What remains of AWS](#what-remains-of-aws) at the end of this page. The hub's
rules are in **The hub runs R2 only** below. The move closed on 2026-10-11.
Why R2: Alex left AWS for a simpler operator experience, not for cost; R2 speaks
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

**Cached headshots reference production.** The NFL headshot seeders
(`nfl:players_seed` via `Nflverse::SeedPlayers`, `nfl:upload_headshots`,
`nfl:upload_coach_headshots`) and the per-player `Athletes::AcquireOrValidate`
call `Studio::ImageCache.reference_or_cache!` (studio-engine 0.103.0), which
takes `cache!`'s arguments. Outside production (QA, a laptop, a desk) it sends a
read-only HEAD to `mcritchie-studio-production` for each missing variant under the
key `cache!` would write. If production holds the key, the row is recorded with
`image_caches.stored_in = "production"` and its `#url` resolves on
`Studio.s3_production_public_url` (`https://assets.mcritchie.studio`, set in
`config/initializers/studio.rb`). If production lacks the key, the variant is
uploaded to the dev bucket as before. In production the helper is `cache!`, so
nothing changes there. Measured 2026-10-10: a missing key answers the dev token
404 (`NotFound`), which is what makes the fallback work. Any other HEAD failure,
such as a 403 from a token without read on production, raises and counts as a
failed upload; it never falls through to a dev-bucket copy.

What the hub does with a reference row:

- **Bytes.** Read through `ImageCache#download`, never
  `Studio::S3.download(key: row.s3_key)`, which reads only the process's own
  bucket. `Athletes::DescribeFromHeadshot` does this.
- **Keys.** `Athletes::RekeyHeadshots` skips a reference off production
  (`.movable?`, counted as `references_skipped`). Production's bucket is
  read-only there, and a repointed reference would name a key production lacks.
  `nfl:upload_headshots` leaves references out of its misfiled count for the
  same reason.
- **Deletes.** `ImageCache#delete_object!` sends no request for a reference off
  production. Destroying the row is always fine.
- **Coach refresh.** When a coach's source URL has changed,
  `nfl:upload_coach_headshots` re-uploads with `cache!`, because production's
  object under the deterministic key may be the old photo.

The test suite leaves `s3_production_public_url` nil, so no test can send a live
HEAD; `test/services/headshot_reference_production_test.rb` sets it and runs the
reference path against a stubbed `Aws::S3::Client`.

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
| `commercial-welding` | `commercial-welding-{dev,production}` | `r2.commercial-welding` | none: no Commercial Welding app exists, so there was nothing to cut over | not enabled |
| `moms-app` | `moms-app-{dev,production}` | `r2.moms-app` | R2 alone since 2026-10-03 (Active Storage `r2`, v25) | enabled 2026-09-26, `moms-app-backup`; drill passed; nightly via `.github/workflows/r2-backup.yml` |

Re-derive before trusting: `GET /accounts/<id>/r2/buckets` with the tier-2
token lists the pairs, and the SOP's verify script re-runs the probes. A census
is only true for the day it was taken.

---

# What remains of AWS

The fleet left AWS on 2026-10-10; the record of what was retired is the plan's
[Wave 7 — the AWS exit record](../system/asset-library-plan.md#wave-7--the-aws-exit-record).
No app holds an AWS credential, and nothing here is a procedure to run. Do not
provision S3 buckets. What Alex kept on purpose:

| What | Why |
|---|---|
| The AWS account | a foothold, in case there is ever a reason to go back |
| IAM user `agents-admin` (1Password item `AWS`, vault `studio-agents-admin`), with `ViewOnlyAccess` and the inline policy `agents-admin-wave7-retire` | the admin foothold; Alex kept both permissions on purpose, "to build trust" |
| S3 `mcritchie-studio-production`: 6 `email/` images | emails already sent embed their URLs; kept about one year from 2026-10-10 |
| S3 `turf-monster-production`: 2 `email_banners/` images | the same, about one year |

The S3 rules, credential tiers and census this section used to carry are in git
history: `git show cff9522b7:docs/agents/modules/object-storage.md`.
