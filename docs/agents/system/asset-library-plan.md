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
   *Amended 2026-09-29 (Alex):* music video and artist content uses
   human-readable snake_case keys; see
   [`music-video-pipeline-plan.md`](music-video-pipeline-plan.md#r2-storage).
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

**Proposed, not decided.** The Decisions table and the Shared Drives above are
decided; the Waves states, the writer checklist, the DNS measurements and the
Wave 7 inventory record what exists. These are proposals until Alex says
otherwise: the Wave 2 recipe, the catalog's shape and where it lives, the Wave 4
order, Cloudflare Stream for video and CAD in the business-document tier,
and `DeskCapture`'s private R2 bucket.

## Waves

| Wave | Goal | State |
|---|---|---|
| 0 | credentials | **done**: `cloudflare.studio.provision` filed and verified |
| 1 | R2 foundation | **done**: five pairs provisioned and probed (`r2-bucket-provision-lane`); `Studio::S3` speaks R2 (`studio-s3-r2-endpoint`, released in `studio-engine` 0.77); backup SOP [`r2-backup`](../agents/steffon/sops/r2-backup.md), run nightly for `moms-app` and `mcritchie-industries` |
| 2 | per-app S3 → R2 cutover | **in progress** (2026-09-29): `moms-app` and `mcritchie-industries` R2-primary with an S3 mirror, soaking; `mcritchie-studio` the same since 2026-09-30 (soak to about 2026-10-07); `turf-monster` code shipped and inert, objects pre-copied, DNS on Cloudflare and `assets.turfmonster.media` serving (2026-09-30), cutover next |
| 3 | asset catalog | proposal below |
| 4 | load the collections | after 3 |
| 5 | business documents | **done for McRitchie Studio** (Shared Drives); Commercial Welding open |
| 6 | large media | proposed: video on Cloudflare Stream, CAD in the business-document tier, when the first one arrives |
| 7 | leave AWS | after every app has cut over; inventory below |

## Readiness review — measured 2026-09-28

A read-only pass before Wave 2 execution: bucket listings with the admin AWS key,
`SELECT`s against each production database, config-var **names** per Heroku
app, and a grep of each app's `origin/main`. Numbers are true for that day.

| S3 bucket | Objects | Size | What the database tracks |
|---|---|---|---|
| `mcritchie-studio-production` | 9,303 | 1.04 GB | 3 blobs, 6,146 `ImageCache` rows; the other ~3,150 objects (Pokémon sprites, broadcasts, character sheets) are referenced by stored URL or by nothing |
| `mcritchie-studio-dev` | 11,131 | 1.46 GB | local desks only: `mcritchie-studio-qa` holds no AWS keys |
| `turf-monster-production` | 8,416 | 1.06 GB | 17 blobs (all service `amazon`; none on `amazon_public` today), 8,399 `ImageCache` rows |
| `turf-monster-dev` | 8,457 | 1.07 GB | local desks only: `turf-monster-qa` holds no AWS keys |
| `mcritchie-industries-production` | 120 | 21 MB | 120 `KnowledgeDoc` rows, 0 blobs |
| `moms-app-production` | 3 | 648 MB | 3 blobs (two covers, one audio file, a multipart object) |
| `mcritchie-studio-desk` (`us-east-1`) | 80 | 17 MB | `DeskCapture` |
| `commercial-welding-*`, `mcritchie-industries-dev` | 0 | 0 | nothing; no Commercial Welding app exists on Heroku |

There is no `moms-app-dev` S3 bucket. Only `mcritchie-studio`,
`turf-monster-mainnet`, `mcritchie-industries` (and its QA app) and `moms-app`
hold AWS keys. No app holds `SES_SMTP_*`, so none can select SES: the hub,
`turf-monster-mainnet` and `mcritchie-industries` hold `RESEND_API_KEY`, and
`moms-app` holds no mail credential at all.

**Hard-coded S3 URLs** (columns whose text contains `amazonaws.com`, scanned in
every text and JSON column): only the hub has any.

| Hub column | Rows | Points at |
|---|---|---|
| `task_events.metadata` → `mascot` | 14,707 | `mcritchie-studio-production/pokemon/…` sprites, snapshotted per board event |
| `pokemons` (8 URL columns: sprite, avatar, fallbacks, shiny, female) | 494 per column | the same `pokemon/` prefix, written by `lib/tasks/pokemon.rake` before it moved to `Studio::S3` |
| `artifacts.image_url` | 3 | `character-sheets/` |
| `agent_actions`, `agent_activities`, `action_grades`, `tasks.metadata` | a few hundred | URLs quoted inside agent logs and notes: history, not served; leave them |

They keep resolving while the S3 bucket stays public. Before S3 is retired
(Wave 7) the served ones need a rewrite to `assets.mcritchie.studio`. The hub's
Wave 2 task built it: `S3UrlRewrite` (`rake s3_urls:rewrite`) covers the
`pokemons` columns, the mascot avatar, `artifacts.image_url` and
`contents.hook_image_url`/`final_video_url`, touching only URLs that start with
our bucket's host. `pokemon.rake` now builds its URLs from `Studio::S3`. At the
hub's cutover, after the objects are on R2 and `assets.` answers:

```bash
heroku run -a mcritchie-studio -- bin/rails "s3_urls:rewrite[https://assets.mcritchie.studio]"          # dry run: counts per column
heroku run -a mcritchie-studio -- APPLY=1 bin/rails "s3_urls:rewrite[https://assets.mcritchie.studio]"  # write; re-run is a no-op
APPLY=1 bin/rails "s3_urls:rewrite_seed_json[https://assets.mcritchie.studio]"  # locally, then commit pokemon.json so a re-seed keeps them
```

**Per-app verdict.**

| App | Verdict | Why |
|---|---|---|
| `moms-app` | **cutting over**: `ACTIVE_STORAGE_BACKEND=mirror_to_s3` (R2 primary), soaking before step 9 (2026-09-29) | Active Storage only, no `Studio::S3`; now registered in `config/release_repos.yml` (profile `standalone-heroku`) and on `studio-engine` 0.77.3 |
| `commercial-welding` | nothing to migrate | empty buckets, no writer; retire the S3 pair in Wave 7 |
| `mcritchie-industries` | **cutting over**: `ACTIVE_STORAGE_BACKEND=mirror_to_s3` and `STUDIO_S3_BACKEND=r2`, soaking before step 9 (2026-09-29) | on `studio-engine` 0.77.4. Private objects only |
| `mcritchie-studio` | **cutting over**: `STUDIO_S3_BACKEND=r2` and `ACTIVE_STORAGE_BACKEND=mirror_to_s3`, soaking before step 9 (2026-09-30, release v530) | DNS for `assets.` cleared 2026-09-30; the URL rewrite above precedes Wave 7 |
| `turf-monster` | ready: DNS for `assets.` cleared 2026-09-30 | cutover next |

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
   `R2_PUBLIC_URL` yet (an app with public services is the exception: see
   step 3). Keep the `AWS_*` variables.
3. **Mirror Active Storage, keeping the service names.** Every blob row
   records its service by name (`amazon`, and turf-monster's `amazon_public`),
   so rename, do not add: move the existing S3 definition to `amazon_s3`, add
   `r2`, and redefine `amazon` as `service: Mirror, primary: amazon_s3,
   mirrors: [r2]`. Existing rows resolve to the mirror unchanged. Do the same
   for `amazon_public`, but its R2 half is **not** a stock `S3` service with
   `public: true`: Rails builds a public URL from the client endpoint, so on R2
   it names `<account>.r2.cloudflarestorage.com`, which answers no anonymous
   read. It needs a small custom service, an `S3Service` subclass whose
   `public_url` is `R2_PUBLIC_URL` plus the key (turf-monster's
   `R2PublicService`). The `public-read` ACL `public: true` sends is harmless:
   R2 accepts the header and ignores it (measured 2026-09-29). Because the
   mirror serves URLs from S3 only until step 8, it is tempting to defer the
   domain, but **an app with a public service needs `R2_PUBLIC_URL`, and so
   the step 6 domain, before this step**: turf-monster's storage config
   refuses to boot any non-`s3` stage without it. In the apps built so far this
   step is the config var `ACTIVE_STORAGE_BACKEND` walking `s3` →
   `mirror_to_r2` → `mirror_to_s3` → `r2` (steps 3, 8 and 9 here), not a rewrite of
   `storage.yml` per step. From here every new upload
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
   here; step 7 catches them up. **Also compare whole buckets**, because a
   database-key check cannot see objects no row names (about a third of the
   hub's production bucket, measured 2026-09-28): `rclone check --one-way` S3 →
   R2 may miss only `Studio::S3` keys written after step 4, and `rclone size`
   on each bucket must show R2's count and bytes at or above S3's. At step 7's
   re-run the one-way check must miss nothing.
6. **Public domain** (apps that serve public objects; needs the domain's DNS
   on Cloudflare first, see **Blocker for step 6** below). Attach
   `assets.<domain>` to the R2 production bucket (by API with
   `cloudflare.studio.provision`, see [`object-storage.md`](../modules/object-storage.md))
   and fetch one copied object through it.
   Still no `R2_PUBLIC_URL`. An app with a public Active Storage service
   (turf-monster) runs this step **before step 3**, fetches a test object
   instead, and sets `R2_PUBLIC_URL` here: its storage config needs it on
   every non-`s3` stage, while `Studio::S3` still reads it only once step 7
   turns the switch on.
7. **Flip `Studio::S3` — one deploy.** Set `R2_PUBLIC_URL` (already set on an
   app with a public service, see step 6) and turn the switch
   on in the same config change, so writes and URLs move together. A
   private-object app has no `assets.` domain and sets no `R2_PUBLIC_URL`; it
   must first confirm nothing calls `Studio::S3.url`, which raises on R2
   without one (`moms-app`, first in the order, is such an app). Then at once
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
| `mcritchie-studio` | `lib/tasks/pokemon.rake` | ported to `Studio::S3` (client and URL base); the `pokemons` URL columns it wrote before the port still need the rewrite above |
| `mcritchie-studio` | `Appearances::StoreGeneratedImage` | uploads via `Studio::S3` and **stores the returned URL** |
| `mcritchie-studio` | `Athletes::DescribeFromHeadshot` | downloads via `Studio::S3` |
| `mcritchie-studio` | `Athletes::RekeyHeadshots` | copies then deletes keys via `Studio::S3`; do not run it between step 4 and step 7 |
| `mcritchie-studio` | board history | `task_events.metadata.mascot` snapshots sprite URLs; rewrite with the `pokemons` columns |
| `mcritchie-studio` | `DeskCapture` | its own **private** bucket, `mcritchie-studio-desk` (`DESK_CAPTURE_BUCKET`, region `DESK_CAPTURE_REGION`, default `us-east-1`), deliberately not `Studio::S3`'s. The main inbound path is already Resend: `DeskCaptureResendIngestJob` stores the raw mail there with the app's AWS keys. SES inbound is only the manual fallback (`DeskCapturePollJob`). Its move is a private R2 bucket of its own plus retiring the SES fallback. Since 2026-09-29 that bucket exists on R2 (`mcritchie-studio-desk`, one bucket, not a pair; keys `r2.mcritchie-studio-desk`) and the code switches on `DESK_CAPTURE_BACKEND=r2`; the copy and flip are an ops step |
| `turf-monster` | `OgImageAttachable` (`amazon_public` service) and contest, landing-page, site-setting attachments | public; needs `assets.` |
| `mcritchie-industries` | `Slack::ChannelIngest` (storage defaults to `Studio::S3`) | private |
| `moms-app` | Active Storage only: `Book.cover`, `Book.audio`, `User.avatar`; the bucket comes from `S3_BUCKET` in `config/storage.yml` | no `Studio::S3`; one multipart audio object, so verify by size |
| `commercial-welding` | none: no app on Heroku, and both S3 buckets were empty on 2026-09-28 | nothing to cut over; retire the S3 pair in Wave 7 | |

**Blocker for step 6** (and so for turf-monster's step 3, above), **cleared
2026-09-30.** R2 custom domains need the domain's DNS on Cloudflare in the same
account. On 2026-09-26 `mcritchie.studio` was served by Google's nameservers
and `turfmonster.media` by Squarespace's; since 2026-09-30 both zones are
Active on Cloudflare with every record DNS only, and both `assets.` domains
serve their production buckets. `turfmonster.media` is the domain Turf
Monster serves from: it is the production `smoke_url` in
`config/release_repos.yml` (app `turf-monster-mainnet`). Moving each domain's DNS to Cloudflare is the CDN rollout
([`cdn-rollout.md`](cdn-rollout.md)) and Steffon's `domain-dns` SOP; it must
carry the Google Workspace mail records across. The three private-object apps
do not need it; `mcritchie-studio` and `turf-monster` go last partly for this
reason. The provisioning token attached both `assets.` domains itself by API
(2026-09-30), so no dashboard step remains.

**The move cost Turf Monster about an hour of outage (2026-09-29 23:17 →
2026-09-30 00:23 MDT), and the lesson binds the next domain.**
`turfmonster.media` had DNSSEC published at the `.media` registry. Squarespace's
"disable DNSSEC to change nameservers" dialog stops signing at once, while the
registry keeps the DS record (TTL 3600) until the registrar pushes its removal,
about 15 minutes here. Every validating resolver (1.1.1.1, 8.8.8.8, 9.9.9.9)
failed the domain in between and for up to an hour after, from cache. The same
dialog also saved the wrong nameserver pair; Squarespace pushes each save about
15 minutes later, in order. Splitting the steps does not remove the outage:
where the registrar stops signing before the registry drops the DS (Squarespace
does), the domain is dark from that save until the DS is gone plus its TTL. So
for any domain with a DS record (`dig DS <domain>` at the TLD server), schedule
that window with Alex, disable DNSSEC as its own save, confirm the TLD no
longer returns a DS, wait one DS TTL, then change nameservers; confirm the
domain name on the page before every save. `mcritchie.industries` has a DS
today (measured 2026-09-30).

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
  The read-only first cut is built (`asset-tree-browser`): an admin folder
  tree over the bucket's key prefixes, read through `Studio::S3`, with a name
  search bounded to 5,000 keys under the open folder and signed previews.
  It has no catalog table yet; upload, approve and retire wait on this wave.
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
| S3 desk-capture bucket `mcritchie-studio-desk` (`us-east-1` by default) and the **SES inbound** fallback | `team@mcritchie.studio` capture (`DeskCapture`); the main path is already Resend inbound, which writes into this bucket | a private R2 bucket for `DeskCapture` alone (provisioned 2026-09-29), then retire the SES fallback (`DeskCapturePollJob`) with the AWS exit: SES inbound drops into S3 only, so once the desk reads R2 the poll has nothing to read |
| **SES outbound** (`agent.aws.mcritchie-ses`) | nothing: on 2026-09-28 no app held `SES_SMTP_*`; the three apps that send mail hold `RESEND_API_KEY` | retire the credential and the SES identity |
| **S3 URLs already handed out** | full `amazonaws.com` URLs outside the key-to-URL path: stored columns (`Content#hook_image_url` and `#final_video_url` keep what `Studio::S3.upload` returned; the `pokemons` URL columns `pokemon.rake` wrote before it moved to `Studio::S3`), images in broadcasts already sent, and og:image URLs unfurlers cached | before deleting a bucket, rewrite stored URLs to `assets.<domain>` and decide whether sent mail's `email/` images keep an S3 copy; none of these move with the Wave 2 config |
| IAM users (`mcritchie-s3`, `mcr-*`, `mcritchie-ses`, and the admin key's user, which answers as `agents-admin`) | the keys above | delete after their buckets are gone; `mcritchie-ses` now (see **IAM users** below) |
| 1Password items (`agent.aws`, `AWS`, `mcritchie-industries.aws`, `agent.aws.mcritchie-ses`) | the keys above | mark RETIRED in the inventory's name or vault cell |

### Measured from the account, 2026-09-29

Read-only, account `534727954137`, with the admin key (`AWS` in
`studio-agents-admin`) and, for SES, `agent.aws.mcritchie-ses`. A re-run before
the exit must re-measure every row.

**Buckets (10: nine in `us-east-2`, `mcritchie-studio-desk` in `us-east-1`).**
R2 copy state is from an `rclone copy` S3 → R2 the same morning; `rclone size` matched on both sides unless noted.

| Bucket | S3 versioning | On R2 |
|---|---|---|
| `mcritchie-studio-production` | Enabled | 9,313 objects, 1.05 GB, equal |
| `mcritchie-studio-dev` | none | all 11,131 S3 objects copied; R2 holds 14 objects (about 144 MB) that S3 does not; `rclone copy` never deletes, and the extras are not yet traced. The bucket's archive lifecycle gives old objects a storage class R2 refuses, so the copy needs `storage_class = STANDARD` on the R2 side |
| `turf-monster-production` | Enabled | 8,416 objects, 1.06 GB, equal |
| `turf-monster-dev` | none | 8,457 objects, 1.07 GB, equal |
| `mcritchie-industries-production` / `-dev` | Enabled / none | production mid-cutover: R2 primary, S3 still mirrored (`ACTIVE_STORAGE_BACKEND=mirror_to_s3` on Heroku) |
| `moms-app-production` | Enabled | mid-cutover: R2 primary, S3 still mirrored (`ACTIVE_STORAGE_BACKEND=mirror_to_s3` on Heroku). There is no `moms-app-dev` on S3 |
| `commercial-welding-production` / `-dev` | Enabled / none | empty; nothing to copy |
| `mcritchie-studio-desk` | none | `DeskCapture`'s bucket; its R2 replacement is the private desk bucket |

These copies are a head start, not a cutover: every app still writes to S3
until its Wave 2 steps run, so each cutover still runs its own catch-up copy.

**IAM users (5).** Access-key last use, as AWS reports it:

| User | Path | Last used | Retire when |
|---|---|---|---|
| `mcritchie-s3` | `/` | 2026-09-29, S3 | every app's Active Storage is on `r2`, every `Studio::S3` is on `r2`, the hub's `DeskCapture` is on `DESK_CAPTURE_BACKEND=r2` (on S3 all three sign with this key through `AWS_ACCESS_KEY_ID`), and the AWS config vars are unset |
| `mcr-mcritchie-industries-prod` | `/mcr/` | 2026-09-28, S3 | Industries' Active Storage is on `r2`, its `Studio::S3` (`KnowledgeDoc`, `Slack::ChannelIngest`) is on `STUDIO_S3_BACKEND=r2` (on S3 both sign through `AWS_ACCESS_KEY_ID`), and its AWS config vars are unset |
| `mcr-mcritchie-industries-dev` | `/mcr/` | 2026-09-03, S3 | with the prod user |
| `mcritchie-ses` | `/` | 2026-07-16, SES (before this audit, whose own SES read now shows as its last use) | now: SES inbound delivers as the service, not as this user (see SES below) |
| `agents-admin` | `/` | 2026-09-29, S3 | last, after the buckets are gone |

No roles outside AWS's own service roles.

**SES.** In `us-east-2`, two domain identities, `mcritchie.studio` and
`turfmonster.media`, neither enabled for sending; production access is on. In
`us-east-1` (still in the sandbox), `mcritchie.studio` is not enabled for
sending and the address `alex@mcritchie.studio` is. Neither region sent
anything in the last 24 hours.
Outbound mail rides Resend. The one live use is the inbound fallback into
`mcritchie-studio-desk` (the row above).

**Spend.** Cost Explorer reports about $0.01 a month for S3 in August and
September, and no other service above half a cent. The exit buys nimbleness, not savings.

**Not visible to the admin key.** Its policy grants S3, IAM reads and Cost
Explorer, and refuses EC2, Lambda, RDS, Route 53 (zones and registered domains),
CloudFront and SES. Cost Explorer shows no measurable spend on any of them, which argues
they are empty but does not prove it: Route 53 domain registrations bill once a
year, and free-tier resources cost nothing, so either can tie the account
without showing in August or September. Before closing the account,
Alex checks those consoles with his root login, or grants the admin key
read-only on them for one audit.

## Open decisions and blockers

| Item | Owner |
|---|---|
| Commercial Welding's document tier (Egnyte or Drive) | Alex, after the compliance question |
| Copy `DeskCapture`'s objects to its R2 bucket and flip `DESK_CAPTURE_BACKEND=r2` (bucket and code ready 2026-09-29); retire the SES fallback with the AWS exit | Steffon, before Wave 7 |
| Does Commercial Welding carry CMMC or ITAR obligations? | Alex |
| What writes the `commercial-welding-*` S3 buckets | Steffon, at the start of that app's Wave 2 task |
| Before closing the AWS account, check EC2, Lambda, RDS, Route 53 (zones and registered domains) and CloudFront with the root login: the admin key cannot read them (Wave 7, **Not visible to the admin key**) | Alex |
| Approve or amend the proposals (Wave 2 recipe, catalog, Wave 4 order, Stream and CAD, `DeskCapture` bucket) | Alex |
