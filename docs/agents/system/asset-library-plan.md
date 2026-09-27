# Asset Library Plan — files, documents and assets across the fleet

## Status: Active

Alex set the direction on 2026-09-26: leave AWS for a simpler operator
experience (not for cost), keep business documents where people already work,
and give every app, agent and person one place to find an asset. This page is
the plan and its decisions. The procedures it relies on live in their own SOPs
and are linked, not restated.

## The idea: bytes in a dumb store, meaning in our own system

Every file has two halves. The **bytes** are big and dumb, and belong in the
cheapest reliable store that fits how they are used. **What the file is** —
owner, app, provenance, rights, status, where it is used — is small and
valuable, and belongs in our database. Keep the meaning in our system and the
store becomes replaceable: the next move is one adapter, not a migration.

## Three tiers

| Tier | Holds | Used by | Home |
|---|---|---|---|
| **1. App objects** | uploads, OG images, generated lineups and broadcasts, anything a URL serves | code | **Cloudflare R2**, McRitchie Studio's account, a `<app>-dev` / `<app>-production` pair per app ([`../modules/object-storage.md`](../modules/object-storage.md)) |
| **2. Business documents** | legal, finance, people, brand originals, partner exchanges | people, agents read | **Google Shared Drives** per company |
| **3. Asset library** | logos, people, athletes and teams, content, everyday data | code, agents, people | **bytes in R2, catalog in the hub** (Wave 3) |

Agent knowledge (SOPs, runbooks, insights) stays in git and `KnowledgeDoc`.

**Rules that keep it clean.**

1. One system of record per asset class. Never two editable masters; a copy
   flows one way and records where it came from.
2. Code never reads tier 2 at request time. Drives are for people.
3. Object keys carry no meaning (a UUID or content hash); meaning lives in the
   catalog.
4. Dev/production split everywhere, enforced by keys, not discipline.

## Decisions (Alex, 2026-09-26)

| Decision | Choice |
|---|---|
| Object storage | Cloudflare R2; every app inherits McRitchie Studio's account |
| Business documents for McRitchie Studio | Google Shared Drives. Egnyte declined: the Platform Business plan's 10-seat minimum ($2,640 a year) buys governance McRitchie Studio does not need yet |
| Commercial Welding | **open.** An `Egnyte` login already sits in the `Commercial Welding` vault; decide after learning whether CW carries CMMC or ITAR obligations |
| Public URLs | `assets.<domain>` per app, on the production bucket |
| Backups | yes: Steffon's `r2-backup` SOP (`docs/agents/agents/steffon/sops/r2-backup.md`) (R2 has no versioning) |
| Wave 2 order | `moms-app` → `commercial-welding` → `mcritchie-industries` → `mcritchie-studio` → `turf-monster` |

**McRitchie Studio's Shared Drives** (created 2026-09-26, no prefix because each
company is its own Workspace): `Admin`, `People`, `Brand`, `Content`,
`Turf Monster`, `External`. Alex created them from a proposed set; the
membership rules are the proposal he applied, not a separate decision. Only
`External` admits people outside the company, one folder per partner, shared by
folder and never by drive. `People` admits members only. Agents reach Drive
through the hub's domain-wide delegation key, whose Drive scopes are
`drive.readonly` and `drive.file` (it can read, and create or edit files it
made); it cannot create shared drives or manage membership.

**Proposed, not decided.** Everything below the table above is a proposal
until Alex says otherwise: the Wave 2 recipe, the catalog's shape and where it
lives, the Wave 4 order, Cloudflare Stream for video and CAD in the
business-document tier, and Resend as SES's outbound replacement.

## Waves

| Wave | Goal | State |
|---|---|---|
| 0 | credentials | **done**: `cloudflare.studio.provision` filed and verified |
| 1 | R2 foundation | **done**: five pairs provisioned and probed (`r2-bucket-provision-lane`); `Studio::S3` speaks R2 (`studio-s3-r2-endpoint`, merged to `accepted`, not yet released); backup SOP [`r2-backup`](../agents/steffon/sops/r2-backup.md) merged, enabled on `moms-app` only |
| 2 | per-app S3 → R2 cutover | next, in the order above; blocked until the engine release carrying `s3_endpoint` ships |
| 3 | asset catalog | proposal below |
| 4 | load the collections | after 3 |
| 5 | business documents | **done for McRitchie Studio** (Shared Drives); Commercial Welding open |
| 6 | large media | proposed: video on Cloudflare Stream, CAD in the business-document tier, when the first one arrives |
| 7 | leave AWS | after every app has cut over; inventory below |

## Wave 2 — the per-app cutover recipe

One task per app. An app has **two kinds of writer**, and they move by
different mechanisms:

- **Active Storage** has a built-in `Mirror` service, so its move is reversible
  by config until S3 is dropped from the mirror.
- **`Studio::S3`** (`ImageCache`, `KnowledgeDoc`, email banners and logos, and
  the hub's broadcasts, lineups and reference images) has **no mirror**. It
  writes to exactly one store, so it moves in **one deploy** that switches its
  writes and its public URLs together, followed at once by a catch-up copy.

The recipe:

1. **Adopt the engine.** Bump the app to the `studio-engine` release that
   carries `s3_endpoint` (task `studio-s3-r2-endpoint`).
2. **Config, inert.** Add `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`,
   `R2_SECRET_ACCESS_KEY` (from `r2.<app>`: the prod pair on production, the dev
   pair on QA and locally). In `config/initializers/studio.rb`, set every R2
   `Studio::S3` setting (`s3_endpoint`, `s3_region`, both keys,
   `s3_public_url`) **only when one switch is on**, e.g.
   `ENV["STUDIO_S3_BACKEND"] == "r2"`, and leave it off. Do not add
   `R2_PUBLIC_URL` yet. Keep the `AWS_*` variables.
3. **Mirror Active Storage, keeping the service names.** Every blob row
   records its service by name (`amazon`, and turf-monster's `amazon_public`),
   so rename, do not add: move the existing S3 definition to `amazon_s3`, add
   `r2`, and redefine `amazon` as `service: Mirror, primary: amazon_s3,
   mirrors: [r2]`. Existing rows resolve to the mirror unchanged. Do the same
   for `amazon_public`, but its R2 half is **not** a stock `S3` service with
   `public: true`: Rails builds a public URL from the client endpoint, so on R2
   it names `<account>.r2.cloudflarestorage.com`, which answers no anonymous
   read, and `public: true` also sends a `public-read` ACL, which R2 does not
   support. It needs a small custom service (an `S3Service` subclass whose
   `public_url` is `assets.<domain>` plus the key, and no ACL); without it,
   step 8 turns every og:image into a dead link. From here every new upload
   lands in both stores (the mirror copy is an `ActiveStorage::MirrorJob`, so
   the app's job queue must be running).
4. **Bulk copy.** `rclone copy` the S3 production bucket into the R2 production
   bucket (and dev into dev), with the S3 key and the R2 prod key as two
   remotes.
5. **Verify.** Every `ActiveStorage::Blob` key and every `Studio::S3` key the
   database knows (`ImageCache#s3_key`, `KnowledgeDoc#s3_key`) exists in R2
   with the same size (Active Storage's `checksum` is the base64 MD5; R2's
   ETag is the hex MD5 for a single-part upload, so compare after converting,
   and fall back to size for multipart objects). Active Storage misses must be
   zero. `Studio::S3` objects written after step 4 are expected to be missing
   here; step 7 catches them up.
6. **Public domain** (apps that serve public objects). Attach
   `assets.<domain>` to the R2 production bucket and fetch one copied object
   through it. Still no `R2_PUBLIC_URL`.
7. **Flip `Studio::S3` — one deploy.** Set `R2_PUBLIC_URL` and turn the switch
   on in the same config change, so writes and URLs move together. Then at once
   re-run the step 4 copy **with `--update`** (it copies only what S3 gained
   since, and skips a key R2 already holds newer: several `Studio::S3` keys are
   fixed, such as `email/<file>` and a lineup's `starter_posts/…`, so a plain
   copy would overwrite a post-flip write with the stale S3 object) and re-run
   step 5 including the `Studio::S3` keys: every miss must now be zero. Between
   the deploy and the end of that copy, an object written to S3 in the last
   minutes before the flip can 404 through `assets.`; do this in a quiet hour.
8. **Flip Active Storage.** Redefine `amazon` as `Mirror, primary: r2,
   mirrors: [amazon_s3]`.
9. **Soak** a week, then drop S3: `amazon` becomes the `r2` service alone,
   keeping the name.
10. **Backup.** Enable [`r2-backup`](../agents/steffon/sops/r2-backup.md) for
    the app and run its drill.
11. **Record** the app's row in the R2 census as serving.

**Rollback, honestly.**

| After step | Active Storage | `Studio::S3` |
|---|---|---|
| 2–6 | config only (the mirror writes both) | nothing to undo: still on S3 |
| 7 | config only | **config plus a reverse copy**: turn the switch off and `rclone copy --update` R2 → S3 to carry back what `Studio::S3` wrote to R2 since the flip |
| 8 | config only (S3 is still a mirror) | as above |
| 9 | **a reverse copy**: S3 stopped receiving writes | as above |

### Cutover checklist — every S3 writer we know of

A grep proves a binding, not completeness; re-grep each app for `Aws::S3`,
`Studio::S3` and `has_*_attached` at the start of its task.

| App | Writer | Note |
|---|---|---|
| all | Active Storage (`has_one_attached` / `has_many_attached`) | steps 3, 8 and 9 |
| all engine apps | `Studio::S3` (`ImageCache`, `KnowledgeDoc`, email banners and logos) | step 7; `url` raises on R2 without `s3_public_url`, which is why the switch sets both |
| `mcritchie-studio` | `Broadcasts::Assets.publish` | expects `upload` to return a URL; on R2 it needs `s3_public_url`, which step 7 sets in the same deploy |
| `mcritchie-studio` | `Content::GenerateLineupAssets`, `Appearances::ReferenceImages` | via `Studio::S3` |
| `mcritchie-studio` | `lib/tasks/pokemon.rake` | builds its own `Aws::S3::Client` for `us-east-2`; port or retire |
| `mcritchie-studio` | `DeskCapture` | its own **private** bucket, `mcritchie-studio-desk` (`DESK_CAPTURE_BUCKET`, region `DESK_CAPTURE_REGION`, default `us-east-1`), deliberately not `Studio::S3`'s. The main inbound path is already Resend: `DeskCaptureResendIngestJob` stores the raw mail there with the app's AWS keys. SES inbound is only the manual fallback (`DeskCapturePollJob`). Its move is a private R2 bucket of its own plus retiring the SES fallback |
| `turf-monster` | `OgImageAttachable` (`amazon_public` service) and contest, landing-page, site-setting attachments | public; needs `assets.` |
| `mcritchie-industries` | `Slack::ChannelIngest` (storage defaults to `Studio::S3`) | private |
| `moms-app` | book import and stitching (`BookImporter`, `BookStitcher`) | check how it serves images before choosing public or signed |
| `commercial-welding` | none found: `projects/commercial-welding-llc/` is a diligence document repo, not an app. Find what writes the `commercial-welding-*` S3 buckets (census: recreated 2026-09-01) before its task; if nothing does, the cutover is a copy and the S3 pair retires | |

**Blocker for step 6.** R2 custom domains need the domain's DNS on Cloudflare
in the same account. Measured 2026-09-26: `mcritchie.studio` is served by
Google's nameservers and `turfmonster.media` by Squarespace's (whether
`turfmonster.media` is the domain Turf Monster serves from is an open
question below). Moving each domain's DNS to Cloudflare is the CDN rollout
([`cdn-rollout.md`](cdn-rollout.md)) and Steffon's `domain-dns` SOP; it must
carry the Google Workspace mail records across. The three private-object apps
do not need it; `mcritchie-studio` and `turf-monster` go last partly for this
reason. Measured on the provisioning token the same day: it holds DNS read and
write across every domain in the account, and no Zone Read, which R2 needs to
resolve a domain.

## Wave 3 — the asset catalog

**Model.** One `Studio::Asset` in studio-engine so every app shares it:

| Field | Meaning |
|---|---|
| `key` | object key in the app's R2 bucket (meaningless: UUID or content hash) |
| `checksum`, `byte_size`, `content_type`, `width`, `height` | what the bytes are |
| `category` | `brand` · `person` · `athlete` · `team` · `content` · `everyday` · `document_ref` |
| `subject_type`, `subject_slug` | what it depicts, by slug (the fleet's FK convention): a person, player, team, brand or app |
| `source` | `uploaded` · `generated` · `licensed` · `imported`, with `source_url`, prompt or template for generated, license terms for licensed |
| `rights` | `owned` · `licensed` · `trademark` · `consent_required`, plus `consent_on` for people |
| `status` | `draft` · `approved` · `retired` |
| `visibility` | `public` (served from `assets.`) or `private` (signed URLs only) |
| `usages` | where it is used (polymorphic, many) |
| `drive_file_id` | for `document_ref`: a pointer to a Shared Drive file; no bytes in R2 |

**Categories, and the rule each carries.**

- **Brand**: logos, marks, palettes, templates per company and app. Originals
  live in the `Brand` Shared Drive; the catalog holds the published renditions.
- **People**: headshots and bios. Private by default; `consent_required` until
  a consent date is recorded.
- **Athletes and teams**: keyed to Turf Monster's player and team slugs. Every
  row records its source and license; team marks are trademarks.
- **Content**: generated lineups, broadcasts and social cards, with the prompt
  or template that made them, so a regenerate is reproducible.
- **Everyday**: exports and one-off files. Short-lived; a lifecycle rule on an
  `everyday/` prefix expires them.
- **Document references**: a Drive file id and title only. The document stays
  in Drive.

**Variants.** Resized and cropped renditions come from Cloudflare Images (or
a Worker) keyed on the original, so apps stop resizing in Ruby. `ImageCache`
becomes a read-through onto the catalog, then folds into it.

**Access.**

- **People**: a hub `/assets` browser — search, upload, approve, retire.
- **Apps**: `Studio::Asset.find_by(subject:, category:)`, with URLs from
  `Studio::S3` (public) or `signed_url` (private).
- **Agents**: a read API and an agent tool (search by subject, category and
  tags; return URL, rights and status). Agents may upload drafts; a person
  approves.

**Wave 4 order**: brand first (small, used everywhere), then athletes and
teams (bulk import with source and license per row), then people (with
consent), then content (the generating services write through the catalog).

## Wave 7 — the AWS exit inventory

Retire nothing until every row is replaced. Re-derive the list from the AWS
account before starting; this is what the docs name today.

| AWS piece | Used for | Replacement |
|---|---|---|
| S3 app buckets (`<app>-dev`, `<app>-production`) | Active Storage, `Studio::S3` | R2 (Wave 2) |
| S3 desk-capture bucket `mcritchie-studio-desk` (`us-east-1` by default) and the **SES inbound** fallback | `team@mcritchie.studio` capture (`DeskCapture`); the main path is already Resend inbound, which writes into this bucket | a private R2 bucket for `DeskCapture` alone, then retire the SES fallback (`DeskCapturePollJob`) |
| **SES outbound** (`agent.aws.mcritchie-ses`, `MAIL_TRANSPORT=ses`) | transactional mail wherever an app still selects SES | proposed: Resend, which `Studio::MailTransport` already supports |
| **S3 URLs already handed out** | full `amazonaws.com` URLs outside the key-to-URL path: stored columns (`Content#hook_image_url` and `#final_video_url` keep what `Studio::S3.upload` returned; `lib/tasks/pokemon.rake` hard-codes its `S3_BASE`), images in broadcasts already sent, and og:image URLs unfurlers cached | before deleting a bucket, rewrite stored URLs to `assets.<domain>` and decide whether sent mail's `email/` images keep an S3 copy; none of these move with the Wave 2 config |
| IAM users (`mcritchie-s3`, `mcr-*`, `studio-agents-admin`) | the keys above | delete after their buckets are gone |
| 1Password items (`agent.aws`, `AWS`, `mcritchie-industries.aws`, `agent.aws.mcritchie-ses`) | the keys above | mark RETIRED in the inventory's name or vault cell |

## Open decisions and blockers

| Item | Owner |
|---|---|
| Move `mcritchie.studio` DNS to Cloudflare (hub first), then Turf Monster's app domain | Alex + Steffon (`domain-dns`, CDN rollout) |
| Add **Zone → Read** to the provisioning token | Alex (dashboard) |
| Which domain serves Turf Monster publicly (`turfmonster.media` appears in code) | Alex |
| Automate the nightly `r2-backup` run (task `automate-nightly-r2-backup`, filed 2026-09-26) | Steffon |
| Commercial Welding's document tier (Egnyte or Drive) | Alex, after the compliance question |
| Move `DeskCapture` to a private R2 bucket and retire its SES fallback | Steffon, before Wave 7 |
| Release the `studio-engine` version carrying `s3_endpoint` (Wave 2's gate) | Avi (`qa-release`) and Steffon (`production-deploy`) |
| Does Commercial Welding carry CMMC or ITAR obligations? | Alex |
| What writes the `commercial-welding-*` S3 buckets | Steffon, at the start of that app's Wave 2 task |
| Approve or amend the proposals (Wave 2 recipe, catalog, Wave 4 order, Stream and CAD, Resend) | Alex |
