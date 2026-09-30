# R2 Cutover Record — the hub and Turf Monster

## Status: Active

The record of the two public-object cutovers from AWS S3 to Cloudflare R2
(asset-library Wave 2, [`asset-library-plan.md`](asset-library-plan.md)): what ran,
what was measured, and the **step 7 checklist still owed around 2026-10-07**.
Industries and moms-app followed the plan's recipe earlier; this page covers the
two apps whose objects are public and which needed the DNS move first.

Both runbooks were drafted and verified read-only against production by Carl
before any change, then executed one step at a time with a pre-check on a one-off
dyno before every stage change. Rolling back an Active Storage stage is a
config change; once `STUDIO_S3_BACKEND=r2` is set (step 4), rolling it back also
needs `rclone copy -M --update` R2 → S3, before and after the unset, to carry
back what `Studio::S3` wrote only to R2 (the plan's rollback table).

## Where each app stands

| App | Heroku | Stage | Since | Release |
|---|---|---|---|---|
| `mcritchie-studio` | `mcritchie-studio` | `STUDIO_S3_BACKEND=r2`, `ACTIVE_STORAGE_BACKEND=mirror_to_s3` | 2026-09-30 | v530 |
| `turf-monster` | `turf-monster-mainnet` | `STUDIO_S3_BACKEND=r2`, `ACTIVE_STORAGE_BACKEND=mirror_to_s3` | 2026-09-30 | v297 |

Both serve public objects from `assets.<domain>` (`R2_PUBLIC_URL`), R2 is the
Active Storage primary, and every Active Storage write is still mirrored to S3.
QA (`mcritchie-studio-qa`, `turf-monster-qa`) is untouched and still on S3.

## Rules that apply to both

- **Pre-check every stage on a one-off dyno** before setting it:
  `heroku run -a <app> --env "ACTIVE_STORAGE_BACKEND=<stage>" -- bin/rails runner 'p ActiveStorage::Blob.service …'`.
  Measured on Turf: a bad `ACTIVE_STORAGE_BACKEND` passes the release phase with
  only a warning, then crash-loops web and worker; a bad `STUDIO_S3_BACKEND` fails
  the release.
- **Rollback unsets every stage variable in the same `config:unset` as any
  `R2_*` variable**, or boot raises.
- **Copy with `-M`.** The 2026-09-29 pre-copy ran without it and R2 objects lost
  `Cache-Control` (`public, max-age=31536000, immutable` on S3). Turf's step 3
  re-copied with `-M --ignore-times`; the hub's objects were re-copied the same
  way on 2026-09-30, scoped to files `rclone check` reported identical so no
  newer R2 object could be overwritten.
- **Check the verify command's own output.** `rclone check` prints its summary
  as a `NOTICE` line; filter for "differences found" and "matching files", not
  away from `NOTICE`.
- **Keep the S3 buckets public and intact** until the AWS exit (Wave 7): emails
  already sent embed S3 image URLs, and inboxes cannot be rewritten.

## The hub (`mcritchie-studio`)

Measured before step 1: 3 Active Storage blobs (one `User#avatar`, private,
served by redirect); 6,155 `ImageCache` rows; jobs on Solid Queue (durable);
9,314 objects on S3.

| Step | Result, 2026-09-30 |
|---|---|
| 1. `R2_ENDPOINT`, keys, `R2_PUBLIC_URL=https://assets.mcritchie.studio` (inert) | v527; stages still `s3`/`s3` |
| 2. `ACTIVE_STORAGE_BACKEND=mirror_to_r2` | v528; S3 primary, R2 mirror |
| 3. Catch-up copy and verify | 9,314 files, 0 differences; all 6,158 DB keys on R2 |
| 4. `STUDIO_S3_BACKEND=r2`, catch-up copy | v529; 0 differences; `ImageCache`, headshots and a probe upload answer 200 on the assets domain |
| 5. `s3_urls:rewrite` (APPLY=1) | 3,152 `pokemons` URLs, 4 `artifacts`, 15,625 `task_events` avatars; closing dry run all 0; seed JSON and `e2e/seed.rb` rewritten in their own tasks |
| 6. `ACTIVE_STORAGE_BACKEND=mirror_to_s3` | v530; probe blob on R2 at once, on S3 in 2 s; signed URL on R2 answers 200 |

## Turf Monster (`turf-monster-mainnet`)

Measured before step 1: 19 blobs, all on `amazon` (none on `amazon_public` yet);
8,399 `ImageCache` rows (8,397 headshots, 2 email banners); jobs on Sidekiq
(durable); 8,418 objects on S3; no stored S3 URL anywhere in the database, so no
rewrite step.

| Step | Result, 2026-09-30 |
|---|---|
| 1. `R2_*` and `R2_PUBLIC_URL=https://assets.turfmonster.media` (inert) | v294 |
| 2. `ACTIVE_STORAGE_BACKEND=mirror_to_r2` | v295; probe mirrored to R2 by the worker |
| 3. `rclone copy -M --ignore-times` and verify | 8,418 files, 0 differences; all 8,418 DB keys on R2 and 200 on the assets domain; `Cache-Control` restored |
| 4. `STUDIO_S3_BACKEND=r2`, catch-up copy | v296; headshots and the email banner resolve to the assets domain and answer 200 |
| 5. Re-scan for stored bucket URLs | 0 (only 251 old Redis errors in `error_logs` mention `amazonaws.com`) |
| 6. `ACTIVE_STORAGE_BACKEND=mirror_to_s3` | v297; probe on R2 at once and mirrored to S3; a contest image's signed URL answers 200 |

## Step 7 — owed around 2026-10-07 (Steffon)

For each app, after a clean week (no Active Storage job in retry, dead, or
failed; `/up` 200):

1. **Final copy, Active Storage keys only**, with metadata:
   `rclone copy -M --update --files-from <keys> s3:<bucket> r2:<bucket>`, where
   `<keys>` is `ActiveStorage::Blob.pluck(:key)` from a one-off dyno. Not the
   whole bucket: after step 4, `Studio::S3` writes and deletes happen only on
   R2, so a whole-bucket copy would resurrect deleted objects.
2. **Pre-check `r2`** on a one-off dyno, then set `ACTIVE_STORAGE_BACKEND=r2`.
   Hub: confirm no pending or failed `ActiveStorage::MirrorJob` in Solid Queue
   first. Turf: none in Sidekiq retry or dead.
3. **Hub only:** a last `s3_urls:rewrite` dry run, expecting all 0.
4. **Enable nightly backups** per [`r2-backup`](../agents/steffon/sops/r2-backup.md):
   a `<app>-backup` bucket and keys through
   [`bucket-provision`](../agents/steffon/sops/bucket-provision.md), repo
   secrets `R2_BACKUP_<APP>_*`, and a row in the workflow matrix.
5. Update this page and the census in
   [`../modules/object-storage.md`](../modules/object-storage.md).

**Rollback after step 7** (R2 alone): `rclone copy -M --update` R2 → S3 for all
blob keys first (new uploads exist only on R2), then set
`ACTIVE_STORAGE_BACKEND=mirror_to_s3`. Rolling back `Studio::S3` as well needs
the step 4 reverse copy above.

## Still owed

- **QA passes.** `mcritchie-studio-qa` (dev bucket, mirror stages like
  production) and `turf-monster-qa` (holds no AWS keys, so it goes `s3` → `r2`
  in one move). Each needs a public URL on its R2 dev bucket (for example
  `assets-dev.<domain>`, never the production domain), a catch-up
  `rclone copy -M` of the dev bucket, a key-presence check, and one
  `config:set` of all five variables after a one-off-dyno pre-check.
- **DeskCapture** stays on its own S3 bucket (`mcritchie-studio-desk`) until
  `DESK_CAPTURE_BACKEND=r2`, a separate step in the plan's open decisions.
- **AWS keys stay** on both apps until the AWS exit: the S3 half of the mirror
  and DeskCapture still use them.
