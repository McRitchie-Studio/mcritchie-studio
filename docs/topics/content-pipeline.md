# Content Pipeline

> **When to read this:** Adding/modifying Content services, the Starter Post X workflow, the Starter Post TikTok workflow, lineup graphic capture, or video assembly.

`app/services/content/` contains 6 manual service classes + 5 AI agents (reopening the `Content` class). Manual services accept pre-computed fields and advance stage. AI agents call external APIs then delegate to the manual services.

## Services + Agents

- `Content::Hook` — idea → hook (hook_image_url, hook_ideas, selected_hook_index)
- `Content::Script` — hook → script (script_text, duration_seconds, scenes)
- `Content::Assets` — script → assets (scene_assets)
- `Content::Assemble` — assets → assembly (final_video_url, music_track, text_overlays, logo_overlay)
- `Content::Post` — assembly → posted (platform, post_url, post_id, posted_at)
- `Content::Review` — posted → reviewed (views, likes, comments_count, shares, review_notes)
- `Content::ScriptAgent` — Claude Opus generates script/scenes from player context → delegates to `Content::Script`
- `Content::AssetsAgent` — Higgsfield (Nano Banana) generates scene images → delegates to `Content::Assets`
- `Content::AssembleAgent` — Higgsfield (Kling 3) generates video from scene images → delegates to `Content::Assemble`
- `Content::Finalize` — FFmpeg watermark overlay (stub pending buildpack). Updates `logo_overlay`. **Note:** despite the `_agent` suffix on its rake task (`content:finalize_agent`) and route (`POST /contents/:slug/finalize_step`), this is NOT an AI agent — it's a deterministic FFmpeg post-processing step that runs after `assemble_agent`. Sits in the `assembly` stage but marks the video finalized.
- `Content::MetadataAgent` — Claude Haiku generates TikTok captions, hashtags, music suggestions. Can run at any stage.
- `Higgsfield::Client` — Shared HTTP client (`app/services/higgsfield/client.rb`). Auth via a single `Authorization: Key <id>:<secret>` header against `api.higgsfield.ai`. Submit + poll pattern with 5-min timeout. (The `hf-api-key`/`hf-secret` pair belonged to the retired `platform.higgsfield.ai` host — see **Feature status** below.)

## Rake Tasks

`content:hook`, `content:script`, `content:assets`, `content:assemble`, `content:post`, `content:review` (manual). `content:script_agent`, `content:assets_agent`, `content:assemble_agent`, `content:finalize`, `content:metadata` (AI). `content:generate SLUG=xxx` (full pipeline). All support `SLUG=` override.

**Feature status: BLOCKED ON CREDITS AND THREE BUILD GAPS.** The client was
rewritten on 2026-09-20 against the current API, so the integration itself is no
longer broken. But topping the account up does NOT make this pipeline produce a
postable video, and it would be an expensive thing to believe. Three gaps sit
between a credited call and something publishable:

1. **No posting door for the workflow this path produces.** `contents.workflow`
   defaults to `"video"`, and `TIKTOK_WORKFLOWS` is
   `starter_post_tiktok_offense`/`_defense` ONLY — so `post_to_tiktok` and
   `studio_upload_to_tiktok` both raise "Only available for TikTok workflows",
   and `post_to_x` requires `starter_post_x`. No publish path accepts a
   `"video"` Content.
2. **No audio.** There is no TTS or voiceover anywhere in `app/`, `lib/` or
   `config/`, while `ScriptAgent` writes a NARRATED 15-30 second script. The
   script gets written and then never spoken.
3. **One-scene assembly.** `AssembleAgent` builds one clip from
   `image_urls.first` of the five images `AssetsAgent` paid for, and passes no
   duration.

Top the credits up today and what comes out is a silent ~5s clip, built from one
of five paid images, carrying none of the script, that no publish path will
accept.

**What the rewrite fixed.** `Higgsfield::Client` used to target
`platform.higgsfield.ai` with `hf-api-key`/`hf-secret` headers, paths
`/v1/text2image/soul` and `/v1/image2video/dop`, and polling at
`/v1/job-sets/{id}`. That surface is partly decommissioned — it still
AUTHENTICATES our key and still serves `GET /v1/motions`, so a shallow probe
looks healthy, but the image path answers `400 {"detail":"Unavailable model"}`.
Its `width_and_height: "1024x1792"` is also no longer accepted (the 422 names
the current set; `1152x2048` is exact 9:16). This is why the feature read as
"built but untested" for months rather than as broken.

The client now targets, all measured live:

| | Current |
|---|---|
| Host | `api.higgsfield.ai` |
| Auth | `Authorization: Key <id>:<secret>` |
| Image | `POST /higgsfield-ai/soul/v2/standard` (requires `prompt`) |
| Video | `POST /kling-video/v2.5-turbo/pro/image-to-video` (requires `prompt`, `image_url`) |
| Poll | `GET /requests/{request_id}/status` |

`Higgsfield::Client::VERTICAL_9_16` (`1152x2048`) replaces the retired size, and
the video model moved from a body field into the PATH — so `generate_video`
REFUSES a non-nil `model:` rather than accepting and ignoring it.

### Character identity — generating THIS person, not a person

Without an identity, "a quarterback mid-throw" invents a new face on every call
and a five-scene run comes back as five different men. Higgsfield's **custom
reference** fixes that: post a set of reference photos once, get a UUID, then
every generation naming that UUID renders the same face.

Measured live on 2026-09-24 with the production credential — request AND
response, which makes this the one part of the integration whose answers are not
guesses:

| | Measured |
|---|---|
| Create | `POST /v1/custom-references` → **200** |
| Body | `{"name": String, "input_images": [{"type":"image_url","image_url":"https://…"}]}` |
| Read one | `GET /v1/custom-references/{uuid}` → 200 (`status`, `fail_reason`, `reference_media`) |
| List | **none** — `GET` on the collection answers 405, so the id we store IS the record |
| Pin | `custom_reference_id` (UUID) + `custom_reference_strength` on `POST /higgsfield-ai/soul/v2/standard` |

Four validator facts worth not rediscovering, each one a paid round-trip:

- `input_images` items are **objects**. A bare URL string answers 422
  `model_attributes_type`, an item without `type` answers `missing`, and `type`
  is a one-member literal (`image_url`).
- The list has **min_length 1** — `[]` answers `too_short`.
- `custom_reference_id` is validated as a UUID (422 `uuid_parsing` on anything
  else), which is how we know the field is wired rather than ignored.
- `custom_reference_strength` is a **float in 0.0..1.0**, not a level. 99
  answers `less_than_equal`, -5 answers `greater_than_equal`, `"banana"` answers
  `float_parsing`. The client refuses all three locally.

**The identity is not usable when it is created.** The create answers
`status: "not_ready"`, and a poll walked it `not_ready` → `queued` →
`in_progress` → `completed` in about a minute. `thumbnail_url` was still null at
`completed`, so it is not a readiness signal. `Appearance#higgsfield_reference_ready?`
is true only for `completed` — deliberately positive-form, because the inverse
("not one of the pending words") would read a FAILED status as ready.

**The published spec does not list `/v1/custom-references`.**
`docs.higgsfield.ai/docs/openapi.json` carries 8 paths and this is not among
them. The spec is incomplete; the endpoint is live. Probe before concluding
something is absent.

**Where it lives in the app.**

| Piece | File |
|---|---|
| Mint / read | `Higgsfield::Client#create_custom_reference`, `#custom_reference` |
| Which photos (floor) | `Appearances::ReferenceImages` — **injected**, see below |
| Which photos (composed) | `Appearances::ReferenceSet` — the floor plus the chosen search hits |
| Finding more | `Appearances::ImageSearch` (façade) + `::Serper` (paid) + `::WikimediaCommons` (keyless) |
| Ranking them | `Appearances::FaceVisibility` (vision, paid) over `Appearances::PhotoMerit` (free) |
| Filing candidates | `Appearances::GatherReferencePhotos` → `appearance_reference_photos` |
| URL safety | `Appearances::FetchableUrl` → `Studio::ImageCache.validate_source_url!` |
| Mint + record + poll | `Appearances::CreateCharacterReference` |
| Storage | `appearances.higgsfield_reference_id` / `_status` / `_synced_at` |
| Spending it | `Content::AssetsAgent#character_reference` (only when ready) |
| **The page** | `/people/:person_slug/models/:slug` — `AppearancesController#show` |
| Operator | `rake appearances:character_reference SLUG=look-xxx`, `rake appearances:refresh_character_references`, `rake appearances:search_reference_photos SLUG=look-xxx` |

**The reference list is a seam, not a lookup.** Today's floor is the cached ESPN
headshot (`Studio::ImageCache`, purpose `headshot`, variants 100/400, mirrored by
`Nflverse::SeedPlayers#cache_headshot`) plus the operator's `reference_url` when
they have typed one. One image satisfies the API's minimum, so the lane works
now.

**The callable that grows that list now EXISTS; only the credential is missing.**
`Appearances::ReferenceSet` is the composed collaborator — floor first, then the
chosen search hits — and it is what the rake task and the page pass as
`references:`. `Appearances::CreateCharacterReference` was not changed to accept
it, because it already took the list as an injection.

**A SEARCH NO LONGER WAITS ON A CREDENTIAL.** Until 2026-09-26 the line here read
*"waiting on a search" means "waiting on `SERPER_API_KEY`", never "waiting on code"* —
and that was the whole problem: the key was never bought, so the search waited forever
and `ImageSearch.available?` was false on every machine and in production.
`Appearances::ImageSearch::WikimediaCommons` is KEYLESS, ships in the registry behind
Serper, and makes `available?` true everywhere. Read "the gallery is thin" as a question
about the QUERY or the ARCHIVE now, never as a missing purchase.

**Where the found photographs live.** `appearance_reference_photos` holds EVERY
candidate a search returned, chosen or not, with the reason each was passed over
and the query that found it. The reasons are
`app/models/appearance_reference_photo.rb#REJECTION_REASONS`; read the constant's
own comments for what each one means and which of them anything stamps. The
rejects are kept on purpose: the operator's question is "is the search any good?",
and a table of winners cannot answer it — a search returning twenty stock
thumbnails yields the same single winner as one returning twenty good portraits we
capped at `GatherReferencePhotos::CHOSEN_LIMIT`. `ImageCache` is NOT the RECORD of
these: it is unique on `variant` per (owner, purpose) and demands an `s3_key`, so a
candidate we never mirrored could have no row at all and twenty candidates could not
share one (look, purpose) pair.

**But `ImageCache` IS the MIRROR, and the two are different jobs.** Since 2026-09-26
`Appearances::MirrorCandidates` copies every SHORTLISTED candidate into our own S3
before anything is asked to look at it — `owner:` the candidate ROW (not the look, so
the variant-uniqueness constraint is satisfied by construction), `purpose:
"reference_photo"`, `widths: []` so only the original is stored. `AppearanceReferencePhoto`
stays the record of every candidate, mirrored or not; `#hosted_url` reads the copy back
and is nil when there is none. **A caller that finds no mirror must NOT fall back to
`image_url`** — see the classifier section below for what that cost.

**Why the shortlist and not everything.** A reject OUTSIDE the shortlist was rejected by
the FREE metadata score, so re-judging it later costs a re-derivation rather than money;
a reject INSIDE it was judged by a PAID classifier, and every one of those is mirrored,
so no judgement we paid for becomes unrepeatable. It also puts the fetch cost and the
classifier cost under one ceiling (`VISION_SHORTLIST`) instead of letting the mirror
scale with however many results a provider returns.

**The provider is an interface, and it does not assume a credential.** A provider
answers `provider_name`, `available?` and `search(query:, limit:)`, and
`available?` is asked OF THE PROVIDER — so a keyless source (Wikimedia Commons
answers image queries with no key) plugs in without the façade changing — and on
2026-09-26 exactly that happened, in one provider file and one name added to
`providers`, with nothing above it changed.

**TWO PROVIDERS SHIP, ordered paid-first-then-keyless-floor.** The façade serves the
first AVAILABLE provider, so the order is the preference:

| Provider | Credential | Response shape |
|---|---|---|
| `::Serper` | `SERPER_API_KEY` — **never bought, exists nowhere** | **UNVERIFIED.** Reads `imageUrl` alone, treats every other field as optional, skips and COUNTS rows it cannot read. When a key lands, probe once, capture the body, and replace the `assumed_serper_body` fixture in `test/services/appearances/image_search/serper_test.rb` — a green test over a guessed fixture proves the guess is self-consistent and nothing more. |
| `::WikimediaCommons` | none | **MEASURED** against a live 200 on 2026-09-26. Its fixture (`test/fixtures/files/wikimedia_commons_drew_lock.json`) is a verbatim trim of that body, which is the difference between it and the row above. |

Commons was listed SECOND deliberately: it answers `available?` unconditionally, so
listing it first would make a bought Serper key permanently unreachable.

**Two traps in the Commons shape, both pinned by tests.** `query.pages` is a Hash keyed
by pageid and its order is NOT the ranking — the rank is each page's `index`, and the
measured body's keys ran 2, 5, 9, 1, 6. And `url`/`descriptionurl` arrive decorated with
`utm_source`/`utm_campaign`/`utm_content`, which are stripped: `image_url` is half the
unique index, so a campaign tag that ever changed would file one photograph twice.

**No key is a clean degrade, and it is now an unreachable one.** The unconfigured path —
headshot floor only, no Search button, a note naming `SERPER_API_KEY` — is kept, with its
tests, because an empty registry is still a state the façade must render rather than raise
on. But a keyless provider means nothing reaches it in practice, so the panel's copy no
longer reads as "go and buy a key": it says the keyless floor is missing, which is a
registry edit rather than a missing purchase.

**The page is PUBLIC to read and ADMIN-ONLY to spend on.** `#show` is open,
matching the person page it is reached from; `#search`, `#mint` and `#refresh` are
behind `require_admin`, and the three buttons are hidden from everyone else so the
page never offers a control it would refuse. A SESSION IS NOT A COST CONTROL here
and must never be mistaken for one: hub signup is open (magic-link and Google are
both create-or-login), so a login-only gate on these actions means any member of
the public can buy a Higgsfield identity per look and, once `SERPER_API_KEY` lands,
an uncapped search plus up to `GatherReferencePhotos::VISION_SHORTLIST` vision
classifications per click.

**A provider failure lands in `/error_logs`, filed against the look.** Both
paid collaborators degrade to an empty answer rather than raising — which is right
for the page and terrible for diagnosis, because "the key was rejected" and "the
search found nothing" then print the same sentence. `Appearances::FailureLog` is
what keeps them apart: every degrade writes an `ErrorLog` row with the `Appearance`
as its target. So a thin gallery is read by looking for a row on that look FIRST,
not by re-running the search.

### Character sheets — one headshot in, a whole sheet out

**Training is a stage that can refuse, and it kept refusing.** Six measured
attempts against the live Higgsfield API on 2026-09-25/26: four failed at
preparation, always *"We couldn't prepare your photos for training"*, and the
only two that completed used a single tight ESPN headshot. The images FETCHED
fine in every failure, so this is image CONTENT at the training step, never
reachability. A vision pass over the six scouted Sutton photographs explains it:
not one is a front-facing dominant single face.

**So the lane moved to generators with no training step at all.** They carry the
likeness at GENERATION time from as little as ONE face image — and one excellent
front-facing headshot is exactly what we hold for 2,043 athletes.

**The sheet path now HANDS OVER a set and the ROW decides how much of it is sent.**
`Appearances::GenerateArtifact#references` composes floor-first through
`Appearances::ReferenceSet#generation_urls`, and `ImageGeneration::OpenAI` emits one
`input_image` block per reference up to `row.reference_arity` — so "one face image" is
today's registry DECLARATION, not a limit of the code. It was a silent `urls.first`
until 2026-09-27, which dropped three of four distilled photographs with nothing
logged or raised. The row still declares `one`; see the endpoint section below.

#### The endpoint is the finding, and the obvious one is wrong

| Path | Measured result |
|---|---|
| **`POST /v1/responses`, `tools: [{type: image_generation}]`** | **The whole sheet, same man in every panel** |
| `POST /v1/images/edits`, 1 reference | Lost identity on a SINGLE portrait |
| `POST /v1/images/edits`, 5 references | No better |
| `fal-ai/flux-pulid`, 1 reference, one portrait | Identity held, scored 0.75, 4.3s |
| `fal-ai/flux-pulid`, 6-panel grid | **Six different men** |
| `fal-ai/flux-pulid`, 3 calls at one seed | 1 of 3 matched |
| `fal-ai/ideogram/character`, one full body | Likeness held; wardrobe wrong (grey suit, cropped mid-thigh) |
| Higgsfield custom-reference | 4 of 6 mints failed at training |

`/v1/images/edits` **edits** a picture. The Responses tool **looks** at the
reference, reasons, then generates — and that reasoning step is what carries a
likeness across ten panels.

**A PORTRAIT RESULT IS NOT A SHEET RESULT.** The two come apart, which is why
`single_portrait` and `character_sheet` are separate capabilities in the registry
rather than one "identity" flag. flux-pulid holds a portrait beautifully and
returns six different men on a grid.

#### One call, one image, one artifact

A sheet is generated as a SINGLE image in a SINGLE call, and that is why it works:
everything in the frame is generated together, so the panels cannot drift apart.
Five separate calls is precisely the shape that fails. `Appearances::GenerateArtifact`
first shipped generating one pose per call from a five-entry pose map; that was
wrong and was removed.

#### Measured, end to end through this app

| | Measured 2026-09-27 |
|---|---|
| Input | ONE stored ESPN headshot — enough to produce an approved sheet. Whether MORE would be better is **unmeasured on this endpoint** (see below) |
| Output | Ten grid cells carrying eight figures (2 full-body + 6 head views), every one recognisably the subject, correct uniform, number and nameplate |
| Latency | 121.8s |
| Usage | `usage.total_tokens` 7629 — **tokens, not images** |
| Cost | **Not reported.** No token rate is declared, and inventing one would put a figure on the artifact nobody could re-derive |

**Three sheets, not one, and the cost is a RANGE.** Measured through this app's own
code path on 2026-09-27: 7,629 (Courtland Sutton), 7,423 (`bo-nix`), 6,724
(`jaylen-waddle`). A sheet costs **single-digit thousands of tokens**, measured
6,724–7,629. Quote the range or the order and never one sample — the three differ by
900 tokens, so any single figure is stale by the next sheet. `config/image_generators.yml`
owns these numbers.

**"Five references were no better than one" is a finding about `/v1/images/edits`,
and about nothing else.** That sentence was at one time attributed to three different
paths in this repo — the Responses row, the edits endpoint, and the Higgsfield
trainer. Only the edits measurement ever happened. No multi-reference call has ever
been made to `/v1/responses` from this repo, so the sheet row keeps
`reference_arity: one` as a stated, unmeasured belief rather than a finding, and the
row says what would settle it.

**Ten cells, eight figures — one layout, two correct counts.** The sheet is a 5×2
grid, so there are ten CELLS; the two full-body figures each span both rows of their
column, so there are eight FIGURES. "Ten-panel" in the code means the cells. Neither
count is wrong and they are not the same measurement.

#### The pads clause is NOT satisfied, and that is a live defect

Measured twice independently — on the operator-approved v4 and again on this
app's own run:

```
full_body_left_two_have_pads   true
six_head_panels_have_pads      FALSE
reads_as_photo_day_jersey      true
```

The two full-body figures carry pad structure; the six head views show a natural
sloping shoulder line rather than the squared shelf a shoulder pad creates. The
operator approved the LOOK, so this is not a blocker — but the claim that the
prompt's must-hold clause was met is false, and `Appearances::CharacterSheetPrompt`
says so at the top of the file.

**Two transferable lessons.** First: a global styling rule stated ONCE is
overridden by a local description that implies otherwise — "in full pads" at the
top, then panels called "head-and-shoulders portraits", produced photo-day crops.
So every must-hold attribute is repeated INSIDE each panel's own instruction
(`PANEL_SUFFIX`). Second, and the reason the defect survived a check: **a vision
judge answers the question you ask.** "pads visible in all panels" got a generous
yes; "what does a football shoulder pad do to a silhouette" got a clear no. Write
the criterion to describe the OBSERVABLE, never the intent.

Still open: whether per-panel repetition is simply insufficient at a close crop,
or whether the phrasing must describe the silhouette rather than name the
equipment. Repetition alone did not fix it in either run.

#### The generator is a registry row, not a hard-coded vendor

`config/image_generators.yml` declares each generator's adapter, pinned endpoint,
model snapshot, contract version, credential variable, reference-field shape,
billing unit and capabilities. Callers ask for a CAPABILITY and never name a
vendor. **The seam earned itself within a day**: the sheet generator moved from
fal to OpenAI and no caller changed.

**⚠ A ROW RECORDS WHAT WAS MEASURED FOR THAT ROW.** Every row carries a `measured:`
block — what was run, when, and what came back, including the word NOT for
anything untested. This rule exists because it was broken twice in one day:
`fal_ideogram_character` shipped claiming `full_body`, `back_view` and
`expressions` on one weak measurement (`back_view` had never been run at all), and
a report then generalised a `flux-pulid` grid result to "fal", which is two
different rows. A capability with no measurement behind it is a claim the code
acts on that nobody checked.

**Higgsfield stays a row.** It keeps `trained_identity` and the Kling
`image_to_video` job that has never failed, and claims no sheet capability, so
nothing routes it work its training step refuses.

#### Provenance, and why the bytes are ours

Every artifact records `generator`, `generator_endpoint`, `generator_version`
(the pinned MODEL, not the door every model comes through), `seed`, `prompt`,
`billable_units` and `cost_usd`.

**`billable_units` holds two vocabularies**, so the unit is always named: fal bills
a sheet at 3 IMAGE UNITS, OpenAI reports **single-digit thousands** of TOKENS for the
same picture (6,724–7,629 measured). A bare "3" beside a bare four-figure token count
invites one conclusion and it is wrong. A nil cost renders as nothing, never as zero —
not reported is not free.

**A seed is recorded only when it means something.** The Responses image tool
exposes no seed, so the adapter neither sends nor stores one; stamping a seed the
vendor ignored would assert a reproducibility that does not exist.

**The generated image is copied into our own S3 before the row is written**
(`Appearances::StoreGeneratedImage`). Two reasons: OpenAI returns BASE64, and a
multi-megabyte data URI cannot be the value of `artifacts.image_url`; and a vendor
CDN link is not a library — one that 404s in a month is not something the operator
can compare across generators.

#### The iced-out twin and a person's jewelry

Every look a person is given gets an **iced-out twin** (the operator's ask,
2026-10-06: "create Dak model" makes the Dak model and an iced-out Dak model).

- **The twin is its own look**: an `Appearance` with `iced = true` and
  `base_appearance_slug` naming the look it was made from (one live twin per base,
  a partial unique index). Its descriptor is the base's plus ` · iced`, so the
  recast picker and the look dropdown list it as a look of its own
  ("Cowboys white · iced"). It copies the base's team, reference URL and notes,
  never the colorway (`Appearance.file_for_colorway!` must keep finding the base);
  the prompt reads the uniform through the base. It never takes the default.
- **Who makes it**: `Appearances::IcedTwin`, called by both look-creation paths
  (`PeopleController#create_appearance` and the cast card's
  `MusicVideos::CreateRecastLook`) in the same transaction. A look made before
  twins existed gets one from **Create iced twin** on the person page or the look
  page. There is no backfill. Making a twin is a free row.
- **The prompt**: one builder, `Appearances::CharacterSheetPrompt`, with `iced:`
  (defaulting to the look's flag, so `Appearances::GenerateArtifact` is unchanged).
  The grid, the identity rule and the pads clause are the standard sheet's. On top:
  one named pair of designer sunglasses and a jewelry set (a chain, a watch on the
  left wrist, a bracelet on the right, a grill, rings), a consistency clause, and the
  per-panel suffix `ICED_PANEL_SUFFIX` on all eight panels (the repetition rule
  above). Two head views change: "three-quarter looking up" becomes the **rings
  shot** (hands raised to the camera) and "front smiling" becomes the **grill shot**
  (a big smile).
- **Jewelry is a person's record**, `person_jewelries` (`PersonJewelry`): `kind`
  (`super_bowl_ring`, `championship_ring`, `chain`, `watch`, `bracelet`, `grill`,
  `other`), `name`, `year` (required for the two ring kinds), `description` (the
  text the prompt uses), an optional `image_url` (https on a public host) and
  `source`. Admins add, edit and remove them on the person page. The iced prompt
  names and describes the person's ring records; with none it asks for generic
  diamond rings. Any other kind with a record replaces its generic piece; `other`
  pieces are added. Nothing seeds real people's jewelry.
- **Builds stay explicit, because each sheet is a paid image.** Creating a look
  builds no twin sheet on its own. The cast card's Generate-a-look form asks which
  sheets to build: **Character sheet** (one build, the default), **Iced sheet
  only** (one), **Both sheets** (two, and it says so) or **No sheet yet**. The look
  page builds its own sheet; a base look with an idle twin also offers **Generate
  both: this and <twin> (2 paid builds)**. Each build is its own claim and job in
  `Appearances::SheetBuild`.

#### Where it lives in the app

| Piece | File |
|---|---|
| The registry | `config/image_generators.yml` |
| Loading it | `ImageGeneration::Registry` (`.for(:character_sheet)`, `.preferred`) |
| The sheet vendor | `ImageGeneration::OpenAI` (Responses + `image_generation` tool) |
| The portrait vendor | `ImageGeneration::Fal` — one class, many rows |
| Choosing the class | `ImageGeneration::Adapter.for(row)` |
| Shared failure type | `ImageGeneration::GenerationFailed` |
| Normalised answer | `ImageGeneration::Result` |
| The prompt | `Appearances::CharacterSheetPrompt` (`iced:` for the iced-out variant) |
| The iced twin | `Appearances::IcedTwin`; `appearances.iced`, `appearances.base_appearance_slug` |
| A person's jewelry | `PersonJewelry` (`person_jewelries`), `PersonJewelriesController` — `require_admin` |
| The use case | `Appearances::GenerateArtifact` |
| The reference set it sends | `Appearances::ReferenceSet#generation_urls` (floor first) |
| How many of them go | `reference_arity` on the row, honoured by both adapters |
| Our copy of the bytes | `Appearances::StoreGeneratedImage` |
| Route | `POST /people/:person_slug/models/:slug/generate` — `require_admin` |
| Suite traps | `OPENAI_NO_LIVE_CALLS=1`, `FAL_NO_LIVE_CALLS=1`, armed in `test/test_helper.rb` |
| Autoload | `open_ai.rb` needs the inflection in `config/initializers/inflections.rb` |

#### Characters: looks owned by our fictional cast

A look (`Appearance`) belongs to **exactly one** owner: a `Person` (a real human)
or a `Character` (our cast: a `mascot` or a `puppet`, e.g. Turf Monster). The
`appearances_exactly_one_owner` and `artifact_subjects_exactly_one_owner` CHECK
constraints hold it in the database; `Appearance#owner` and `#owner_name` answer
either. Both owners resolve and release their default look through one concern,
`HoldsDefaultAppearance`.

- **Owner-generic:** the default-look pointer, `ArtifactSubject` (a character's
  sheet files `character_slug`), `Appearances::SheetBuild` /
  `Appearances::GenerateArtifact` (a character's anchor is its own reference art;
  its prompt is `Appearances::CastSheetPrompt`, with no person or likeness
  wording; its sheet is stored under `character-sheets/characters/<slug>/`),
  `Artifact.newest_character_sheets`, `AppearanceReferencePhoto` (source `upload`
  is character art and is never face-judged).
- **Person-only:** the model pipeline board (`Appearance.person_owned`), every
  recast picker (`Appearance.recastable`), the people pages and their model
  thumbnails, the content cast and reuse key, `Appearance.file_for_colorway!`,
  the iced twin (refused for a character), the Higgsfield identity mint (refused
  for a character) and the likeness search (a character has no person name, so
  it searches nothing).
- **Pages:** `/characters` and `/characters/:slug` (`CharactersController`,
  `require_admin`): the cast, a profile, its looks with art and sheet status, art
  uploads (`Characters::UploadLookArt`, PNG/JPEG/WebP read from the bytes, 5 MB,
  stored under `characters/<slug>/refs/`) and a paid **Build sheet** button. A
  brand kit page links its live character (`Character.featured_for`).
- **Seed:** `bin/rails characters:seed_turf_monster` (idempotent, never
  overwrites an edit, generates nothing) creates Turf Monster and his default
  "Classic" look from the Turf kit's references.

**The identity photo reads the STORED `s3_key`, never a rebuilt path.**
`Athlete#headshot_url` resolves the `ImageCache` row and calls `ImageCache#url`;
`Athlete#headshot_key_prefix` is a WRITE-time builder. `Athletes::RekeyHeadshots`
is actively moving athletes out of `headshots/nfl/free-agents/`, so a rebuilt path
points at an object that has already moved. This path prefers the `original`
variant — deliberately unlike `Appearances::ReferenceImages::HEADSHOT_VARIANTS`
(`%w[400 100]`), because that list feeds a TRAINING set while this feeds a
generator reading one image.

**The jersey number is in the data model, and this recipe still does not read it.**
`athletes.jersey_number` landed 2026-09-27 (`Athletes::AcquireOrValidate`, `:roster`
policy); before that no table carried one and the approved reference sheet's "14" was
supplied by hand. `Appearances::CharacterSheetPrompt` takes `number:` as a caller's
argument and reads no column, deliberately: wiring it changes the text of every
generated prompt, and a prompt change costs money to evaluate and owes its own
before/after artifacts. Until then the page offers an optional number field; left
blank, the prompt omits the number and nameplate clauses rather than asking the model
to render a placeholder.

**⚠ `POST https://queue.fal.run/<model>` submits billable work on ANY body**,
including an empty one. Probe fal with the GET status endpoint: a real key answers
404 for an unknown request id, a bogus key answers 401. And fal's published
OpenAPI status path is wrong for sub-path models — it documents
`/fal-ai/ideogram/character/requests/{id}/status`, the live host answers 405, and
the queue routes under the first TWO segments. The submit response returns
`status_url` and `response_url` fully formed; use those.

### Ranking the candidates — why a helmet is not a reference photo

The operator's words: *"we should prioritize pictures with no helmet so the face
has more details."* He is right for a structural reason: a character identity is
built from a face, and a helmet occludes exactly the features it is built from.

**The provider's own rank cannot answer this.** It orders by ITS idea of relevance,
which says nothing about whether you can see anyone. Measured on the operator's own
labelled look: the provider's hit 1 and hit 2 were a bare-faced photograph and a
helmeted one, same person, days apart, near-identical portrait ratios (0.71 vs
0.74) and near-identical titles. **No metadata signal available to us orders that
pair correctly** — which is why the ranking is a VISION call and not a heuristic.
`Appearances::PhotoMeritTest` pins that limit as a test so nobody deletes the
classifier to save money.

**Two scores, and they do different jobs.**

| | `PhotoMerit` | `FaceVisibility` |
|---|---|---|
| Cost | free, metadata only | **bills per image** |
| Decides | who is worth PAYING to look at | the actual order |
| Can it spot a helmet? | **no** | yes |
| Runs when | always | only with `ANTHROPIC_API_KEY` |

The classifier is asked in batches of `FaceVisibility::BATCH_SIZE` until the shortlist
(`GatherReferencePhotos::VISION_SHORTLIST`, currently 24) is spent — three requests at a
batch of 8, never one message, so a single unreadable file costs its own batch rather
than every judgement in the shortlist. Anthropic
fetches the images server-side from a `type: "url"` source — the same trust
boundary Higgsfield's create sits behind, and the same obligation: only URLs that
have cleared `Appearances::FetchableUrl` are ever passed.

**AND ONLY URLs WE SERVE.** Every shortlisted candidate is mirrored into our own S3
first (`Appearances::MirrorCandidates`) and the classifier is handed the copy. A
candidate that could not be mirrored is simply not classified — it is never sent as a
remote URL, because that is the defect:

**Prioritise, never starve.** A helmeted photograph still goes into the identity
when nothing better exists — measured on a real Commons answer for "Drew Lock",
exactly ONE of twenty hits was bare-faced. The one HARD exclusion is
`not_a_photo`: a scanned book page or a diagram, which is not a poor reference but
no reference at all. Documents are also never sent to the classifier — measured on
that same answer, 12 of the 20 candidates were documents, so the paid shortlist
drops from 12 images to 8. That rule exists because of a real defect — with a blind
take-the-top-N, an 1896 edition of *The Rape of the Lock* was selected into a
character model.

**⚠ IT HAS NOW BEEN DRIVEN LIVE, AND IT FAILED — measured on production
2026-09-26**, during the first real scouting run (`jaxon-smith-njigba`). This
paragraph previously read *"No `ANTHROPIC_API_KEY` exists on any machine or in any
readable vault, so it has never been driven against the live API"*; that is no longer
true of production, and a 400 rather than a 401 is itself the evidence the key was
accepted. (`credential-inventory.md` records where the vault item is NOT filed, which
is a different question and still stands.) What the run returned, on every image:

```
[Appearances::FaceVisibility] Anthropic answered 400:
  {"type":"error","error":{"type":"invalid_request_error",
   "message":"Unable to download the file. Please verify the URL and try again."}}
```

**The cause was hotlink policy on the source host, not an outage and not a bad URL.**
Measured against the exact failing URL: `curl` **with** a User-Agent → 200 `image/png`;
**without** one → **403**. Wikimedia refuses a request that sends no User-Agent, and
Anthropic's fetcher was the party being refused. Our own fetcher is not — `URI.open`
sends Net::HTTP's default `User-Agent: Ruby` and answered 200 with 222,045 bytes — which
is why mirroring fixes it and a retry would not.

**The asymmetry this explains:** Higgsfield fetches the same Wikimedia URLs
successfully (its `reference_media` comes back re-hosted on its own CDN), so one
consumer worked and another did not, from the same URL, with nothing in our code to
tell them apart. Any source host may hotlink-protect, so the fix is architectural:
mirror first, then hand out our own URL.

**What the silence cost, and why "loud" is now a requirement.** The classifier degrades
to an empty Hash by contract, so the run continued with NO face scores, ranking fell
back to title-match and aspect ratio, and SIX photographs entered the character model —
**three of them aircraft** (`9V-JSN` and `HB-JSN` are registration codes sharing the
athlete's initials). The operator read it off the page before we did, because the page
reported a green notice. `Summary#face_classifier_blind?` now separates **zero scores
from N attempts** from **N photographs that scored zero**: the flash becomes an ALERT
naming both counts (`0 of 8 shortlisted scored (8 mirrored and sent)`), and one
`ErrorLog` row is filed against the look. It keys on `shortlisted`, not `attempted`, so
a total MIRROR failure is equally loud rather than reading as "nothing to do".

Still owed: the request shape comes from the documented Messages API, and no 200 has
ever been observed. Pin a real response body as a fixture in
`test/services/appearances/face_visibility_test.rb` on the first successful run.

**⚠ Known gap: face visibility is not identity.** A clear photograph of the WRONG
person outranks a helmeted photograph of the right one, because that is exactly
what the classifier was asked to judge. Measured: "Drew Hutton" was hit 5 in a real
Wikimedia answer for "Drew Lock" and ranks second under this scoring. The gallery
prints every candidate's title so a human can see it; a comparative
"is this the same person as the others?" pass in the same call is the obvious next
step and is NOT built.

**⚠ Biasing the QUERY toward faces was tried and REFUTED — do not re-add it
without re-measuring.** The intuition (append "press conference", "portrait",
"headshot") is wrong in every form measured against Wikimedia Commons on
2026-09-26:

| query | results | photographs | of the right person |
|---|---|---|---|
| `Drew Lock` | 20 | 8 | **3** |
| `Drew Lock press conference` | 20 | 0 | 0 |
| `Drew Lock portrait` | 20 | 1 | - |
| `Drew Lock headshot` | 0 | 0 | 0 |
| `Drew Lock press conference portrait headshot interview` | 0 | 0 | 0 |
| `Drew Lock (press conference OR portrait OR headshot)` | 20 | 20 | **0** |

The OR form looks like a win on photograph YIELD and is the worst of the lot: the
modifiers swamp the name and it returns twenty portraits of strangers. Commons
CirrusSearch is not Google, so this does not transfer with certainty — but the
failure mode it demonstrates (a query mutation that silently returns the wrong
people) is not one to ship into a paid path nobody can test.

**Higgsfield fetches our URLs server-side**, so every reference image must be
publicly reachable by THEM, not merely by us. Verified 2026-09-24: a real cached
headshot answers 200 to an unauthenticated `curl -sI`, `Studio::S3.url` builds an
unsigned virtual-host URL, and the created reference came back with the image
re-hosted on Higgsfield's own CDN — which only happens if their fetch succeeded.
A signed or private URL would not survive that hop.

**One live create was made to measure all of the above** (a reference named
`mcritchie-probe-alec-anderson`, id `1af15765-…`). No generation was run, so
nothing here says anything about the credit state of the media endpoints.

**What is still unverified, and why.** The account answers `not_enough_credits`
on every media type, so no successful GENERATION payload has ever been observed.
(The character-identity endpoints above ARE measured end to end, response
included — they mint no media, and a create answered 200.) Request
shapes are measured; RESPONSE parsing is written tolerantly against the
plausible shapes and marked `UNVERIFIED` in the source. Both the URL read and
the status read fail loudly WITH the payload rather than returning nil or
polling out, so the first real generation reports the true shape. An empty pool
raises `Higgsfield::Client::InsufficientCreditsError` specifically, so "top up
the account" never again reads as "the integration is broken".

**Three request fields are also unverified.** `prompt` is the only field the new
image endpoint is PROVEN to require; `width_and_height`, `quality` and
`enhance_prompt` are carried over from the old client and are each a way the
first credited call could 422 under the strict validator the empty-POST probe
proved exists. **On the first credited run, measure the returned image's pixel
dimensions before spending any video credits** — if Soul v2 ignores
`width_and_height`, Kling inherits that frame and we publish a square clip to a
9:16 surface.

A probe order that tells the three failures apart, since they look alike from the
app: a fake-id `GET` proves auth (404 = authenticated), an empty `POST` returns
the schema (422), and only a well-formed POST reveals credits.

Two further gaps to know before trusting the chain end to end:

- **`Content::AssembleAgent` makes ONE ~5-second clip from the FIRST scene image.**
  `AssetsAgent` generates images for up to 5 scenes and `AssembleAgent` then uses
  `image_urls.first` and discards the rest. There is no multi-scene stitching, no
  music, and no text overlays (`music_track: nil`, `text_overlays: []`,
  `logo_overlay: false`).
- **`Content::Finalize` is a labelled stub.** It prints `[STUB] FFmpeg watermark`
  and returns the URL it was given.

### Photo scouting — calibrating the machine's taste against the operator's

`/people/:person_slug/scouting` (`PhotoScoutingController`). The operator's framing:
*"a new page in the model. Where the AI goes out pulls images for the person (athlete)
in this case and then picks the 5 best photos … In this way I should have a good idea of
what the raw found images look like and which ones your taste is picking up."*

**It is a CALIBRATION surface, not a debug view**, and the difference is the verdict
column. A page that only reported would leave the operator's taste in his head; recording
it beside the machine's turns the same page into a labelled set — the only thing that can
tell a future change to the ranking whether it made things better or worse.

| Half | What it shows | Order |
|---|---|---|
| The picks | the chosen set, each with the reasoning underneath | our ranking (`gallery_order`) |
| What the search returned | EVERY raw candidate, rejects included | the provider's own (`found_order`) |

**Both orders are on the page on purpose.** Shown one way only, a bad search and a bad
ranker are indistinguishable — the reader could not tell "the archive handed us twelve
books" from "we sorted twelve books to the top".

**The verdict is two values expressing four cells**, and there is no `promote` value:
`keep`/`drop` is read AGAINST `chosen`, so a keep on a REJECTED photograph already means
"you would have promoted this". A third value would encode the same fact twice and let
the two disagree. `Appearances::Calibration` tallies them; `agreement_rate` is over the
JUDGED rows and is **nil rather than zero** when nothing has been judged, because a fresh
look has no measured disagreement and rendering one as 0 percent is a damning result
nobody earned.

**`:operator_promoted` is the cell worth collecting.** The other three describe how well
the ranker orders candidates it was already going to rank; a promotion says it discarded
something it should have kept, which is the only cell that can teach it something it does
not already believe.

**Only SEARCH rows can be judged.** `Appearances::ReferenceSet` builds the two floor rows
(our mirrored headshot, the operator's typed URL) in memory, so they carry no row to write
to — and they are inputs we control rather than things a search found, so they are not part
of the population under calibration. Those tiles say "not from the search" instead of
showing a control that could not save.

**⚠ The page states its own lane's defects, and must keep doing so.** A calibration surface
that flattered the machine would have the operator tune his judgement to a ranker that does
not behave the way the page implied. It names: the wrong-person ranking defect; that the
top-ranked photograph is usually one Higgsfield refuses to mint; that **the cap is
`CHOSEN_LIMIT` = 8, not the 5 the operator asked for**; and whether anything actually
looked at the photographs. Both ranking defects are owned by task
`reference-photos-wrong-person` and neither is fixed here.

**Mint evidence is REPORTED, never PREDICTED.** `AppearanceReferencePhoto#mint_proven?`
(our ESPN headshot — the one input measured to complete a reference) and
`#mint_shape_failed_before?` (the wide crop shape that failed all four measured mints) are
the only two claims made. Face size in frame is the actual variable and it cannot be
measured. A live classifier does not supply it either, and that is a narrower claim than
the one this line used to make (*"`ANTHROPIC_API_KEY` … exists on no machine"* — production
has one as of 2026-09-26; see the classifier section above). `FaceVisibility`'s prompt DOES
fold size in — *small in frame* scores 0.6, *far from camera* 0.3 — but it gives those same
values to a turned head and a shadowed one, so a score cannot be read BACK as a face size.
A tile therefore says what was measured and stops.

**⚠ The query the pipeline builds can collapse a Commons search.**
`GatherReferencePhotos#query` is the person plus their team, which helps a general image
search tell a quarterback from a locksmith. Commons CirrusSearch ANDs the terms instead, so
the team NARROWS rather than disambiguates. Measured 2026-09-26:

| query | results | photographs |
|---|---|---|
| `Drew Lock` | 20 | 8 |
| `Drew Lock Seattle Seahawks` | **2** | 2 |
| `Drew Lock Denver Broncos` | 20 | 2 |
| `Patrick Mahomes` | 20 | 20 |
| `Patrick Mahomes Kansas City Chiefs` | 20 | 20 |

Precision goes up, recall goes down, and a 2-candidate answer cannot fill a cap of 6. It is
person-specific, it is NOT fixed here, and the page says so where the operator will see it.
Re-derive the table rather than re-copying it.


## The agent surface — where inference lives

**The rule: anything with a right answer stays in code; anything with a JUDGMENT
goes to a soul.** A game's scoreline is a fact and the app records it. Whether
that game was worth posting about, what the take is, and whether a caption
sounds like us are judgments, and they are written by an agent during an SOP
using its OWN inference.

| Deterministic — app code | Non-deterministic — agent inference |
|---|---|
| Game finalises → recap created | Is this game worth posting about? |
| Higgsfield render, given a prompt | The take, the script, the scene list |
| ffmpeg assembly, watermark, music | The caption, the hashtags, the hook |
| S3 upload, stage moves, idempotency | The operator's vibe check before publish |

**Why this and not an API key.** The in-app agents (`Content::ScriptAgent`,
`MetadataAgent`, `PrepForTiktok`, and the three `News::*Agent`s) each do a raw
`Net::HTTP` call to `api.anthropic.com` keyed on `ENV["ANTHROPIC_API_KEY"]`.
**Production HAS that key.** This paragraph used to end *"which production does
not have"*, which made the file contradict its own two corrections above — the
classifier section and the mint-evidence rule both record the key arriving on
2026-09-26. Re-measured 2026-09-28, by name and never by value:

```bash
heroku config --json --app mcritchie-studio | jq 'length'                        # control: 46; 0 = read failed
heroku config --json --app mcritchie-studio | jq '(.ANTHROPIC_API_KEY // "") != ""'   # true
```

The same expression on a name that is absent answered false, which is the
control that makes the true mean something. So key absence is NOT the reason,
and never was the load-bearing one. Routing inference through a soul instead
means prompts that live in SOP prose an agent can improve rather than frozen
string literals in `.rb` files, inference that lands in the agent trajectory
where the learning loop can grade it, and a real voice veto (Mason cannot veto
a line a Rails service already sent). Those services stay in place as the LEGACY path for
`workflow=video`; retiring them is its own task.

**The board is already the queue.** A `Content` at `stage=idea` IS a pending
work item, so nothing new queues anything — the only missing primitives were a
claim and a write-back.

### `/api/v1/contents`

Standard agent bearer auth (`AGENT_API_SECRET`, which production HAS).

| Call | What it does |
|---|---|
| `GET /api/v1/contents?stage=&workflow=&claimable=1` | what is waiting |
| `GET /api/v1/contents/:slug` | the full record, including `game_facts` |
| `POST /api/v1/contents/claim_next` | the ATOMIC pop — the SERVER picks which |
| `PATCH /api/v1/contents/:slug` | the write-back; `stage` advances the card |
| `POST /api/v1/contents/:slug/release` | "I am done, or I gave up" |

**The claim is why this is safe to run more than one of.** `claim_next` selects
`FOR UPDATE SKIP LOCKED` inside a transaction, exactly as
`Task.claim_next_review` does, so two sessions draining the queue together never
block and never collide. Without it they both script the same game and produce
two different takes for one card. The lease is `Content::AGENT_CLAIM_LEASE` (30
minutes) and EXPIRES, so a session that dies mid-SOP does not strand the card;
`release` is refused to a stranger while a claim is live, because re-opening a
card someone is still writing is the other half of the same bug.

**An empty pop is a NORMAL outcome**, answered `200` with
`{"claimed": null, "reason": "none_claimable"}`. Callers idle; they do not
retry-storm.

**The write is deliberately NARROW.** `game_facts`, `game_slug`, `team_slug` and
the score columns are not permitted — they are the deterministic half's record of
what happened, and an agent that could rewrite the scoreline could publish a
video about a game that did not happen. Note `scenes` is permitted by NAMED KEYS
(`number`, `description`, `camera`, `duration`, `characters`): the `scenes: []`
form permits an array of SCALARS only and silently drops every scene, which looks
exactly like a model that wrote nothing.

### `bin/content`

The CLI a soul actually uses: `list`, `show`, `claim`, `write`, `release`.

**Long text goes over stdin or a file, never a shell argument** — a generated
script carries newlines, quotes and `$`, and a shell argument eats all three.
Use `--script -` (stdin) or `--script-file F`; same for `--caption`/`--scenes`.

The session id is per-AGENT-PROCESS (`tmp/content-sessions/<nonce>`), not
per-invocation and **not per-desk**, because a claim and its release are different
processes — a fresh id each time would make every release look like a stranger's,
while ONE id per checkout made two souls working from the hub primary present the
SAME session, which is the collision the lease exists to prevent. The nonce comes
from `SessionIdentity.nonce`, a hash of the long-lived `claude`/`codex` process.

**`CONTENT_SESSION` is a PRECONDITION, not merely an override.** The derived id
separates terminals, not souls: two subagents of one agent process share an
ancestor and therefore a session, and a plain shell or a CI run derives no nonce
at all and falls back to one shared file. Export `CONTENT_SESSION` whenever more
than one soul works the queue — `claim` prints a warning whenever the id was
derived rather than given, for exactly this reason.

## Game Recap Workflow

`Content.workflow = "game_recap"` — one Content per finished NFL game, created at
`stage=idea`. This is the head of the faceless-social pipeline: turf-monster
settles a game, the hub turns it into a content idea.

### The cross-repo seam
Games live in **turf-monster**; Content lives in the **hub**. The hub never reads
turf-monster's database. The whole crossing is one endpoint:

```
POST /api/v1/game_recaps
Authorization: Bearer <token from POST /api/v1/auth>
{ "game": { "game_slug": "...", "home_team_slug": "...", "away_team_slug": "...",
            "home_score": 24, "away_score": 17, "status_detail": "Final",
            "season_year": 2026, "season_type": 2, "week": 3 } }
```

Auth is the standard agent bearer token (`Api::V1::BaseController`, shared
`AGENT_API_SECRET`) — see [`task-board-api.md`](../agents/modules/task-board-api.md).

**Team slugs are shared between the repos.** Both derive from
`"Buffalo Bills".parameterize`, so `buffalo-bills` means the same team on each
side and the payload carries slugs rather than the `BUF`-style abbreviations
turf-monster's `Change` struct reports.

**This is one of two crossings, and the only one that pushes.** The other runs the
other way — turf-monster PULLS the person/athlete projection from the hub — and
the pair, with the design decisions behind them, is described in
[`studio-turf-data-flow.md`](studio-turf-data-flow.md). Read that before adding a
third crossing or changing which app masters a column.

### Idempotency is structural, not incidental
`Nfl::LiveScores::PollCycle` is deliberately safe to re-run — every scoring event
is keyed on ESPN's own play id — so the same final is EXPECTED to arrive here
more than once. A partial unique index on `[game_slug, workflow]` is the arbiter;
`Content::CreateGameRecap` re-reads on `RecordNotUnique` rather than raising, so a
duplicate answers **200 with the existing recap** while the call that created it
answers **201**. A `find_or_create` in the controller would lose that race.

### Title composition
`Content::CreateGameRecap` reads `Team#mascot` (which derives "Broncos" from
"Denver Broncos" minus location when the column is blank — the NFL seed never
populates it) and composes:

- Win: `"Bills Beat Dolphins 24-17"` — **winner first, always**, never home-first.
- Tie: `"Bills And Dolphins Tie 17-17"` — NFL ties are rare but real, and "beat"
  would be a lie, so the phrase changes rather than just the numbers.

`team_slug` holds the WINNER and `rival_team_slug` the loser, reusing the columns
the other workflows use for "us" and "them" so team-colour and hashtag lookups
keep working. On a tie the pair is stored in the feed's home/away order rather
than inventing a ranking. `game_facts` (jsonb) keeps the scoreline verbatim so a
later script step never has to call back to turf-monster.

### Refusals
`Content::CreateGameRecap::InvalidGame` → `422 INVALID_GAME` for: a missing
required field, a team slug the hub does not know, a game played against itself,
a negative score, or a score that is not a whole number. That last one matters —
`"final".to_i` is `0`, which would silently invent a shutout, so the check is
`Integer(..., exception: false)` rather than `to_i`.

## Starter Post (X) Workflow

`Content.workflow = "starter_post_x"` branches the form, services, and show-page UI for an automated "find the mistake in my lineup" X post from @turfmonstershow. Live end-to-end. Pipeline:

1. **Create**: button on `/nfl-rosters` per team → `POST /contents/starter_post_x?team_slug=…` → `ContentsController#create_starter_post_x` creates a Content with `workflow=starter_post_x`, `team_slug`, `source_type=studio`, `stage=script`, and a default `captions` of `"Find the mistake in my <Mascot> lineup 👀\n\n#<Hashtag> <emoji>"`. Redirects to `/contents/:slug/edit`.
2. **Generate assets**: button on the show page (when `stage in [idea, hook, script]`) → `POST /contents/:slug/generate_lineup_assets` → `Content::GenerateLineupAssets` shells out to `script/capture_lineup.js` (Playwright + CDP screencast at 2x device pixels), assembles the PNG-frame sequence into MP4 via `LineupGraphic::AssembleVideo` (lanczos downsample to 1200×1500, **fps=30 cap**, libx264 CRF 16), uploads PNG + MP4 to S3 at `starter_posts/{team_slug}/{content_slug}.{png,mp4}`, saves `hook_image_url` + `final_video_url`, advances stage to `assets`.
3. **Post**: card on the show page (when `workflow=starter_post_x` AND `stage=assets`) offers two paths:
   - **Auto** — `POST /contents/:slug/post_to_x` → `Content::PostToX` downloads MP4 from S3 → `X::PostMedia` (v2 chunked upload + v2 /tweets) → records `post_url`/`post_id`/`posted_at`, stage=`posted`. Disabled if any of `X_API_KEY`/`X_API_SECRET`/`X_ACCESS_TOKEN`/`X_ACCESS_TOKEN_SECRET` are missing.
   - **Manual** — "⬇ Download Video" + "📤 Open X Compose" (intent URL with caption pre-filled, attach video by hand) + paste-URL form → `post_step` extracts post_id from `/status/(\d+)` and saves.

### Schema additions
- **`Content` columns added**: `workflow` (string, default `"video"`, validated against `Content::WORKFLOWS`), `team_slug` (FK → Team).
- **Team metadata columns** — `hashtag` (32/32), `hashtag2` (8/32 — secondary tag for richer captions), `x_handle` (19/32 — for `@`-mentions). Seeded for all 32 NFL teams from `db/seeds/data/teams_hashtags.csv` via `bin/rails teams:backfill_metadata` (also wired into `db:seed` as `13_team_metadata.rb`).

### Lineup graphic page
`GET /teams/:slug/lineup-graphic` (`LineupGraphicsController#show`) renders a 1200×1500 social asset: header → Offense (4×3) | Defense (4×3) side-by-side → Special Teams. Uses its own bare layout `layouts/lineup_graphic.html.erb` (no nav, no Tailwind — inline CSS so screencaps are deterministic). JS exposes `window.startLineupReveals()` so the capture script triggers the reveal cascade only after CDP screencast is live. Reveal cadence is 200ms per tile; 28 tiles total (12 off + 12 def + 4 ST). Auto-starts after 1500ms for human visitors.

### Capture pipeline
`script/capture_lineup.js` uses Playwright + Chrome DevTools Protocol `Page.startScreencast` at 2x device pixels (2400×3000 frames), saves PNG sequence to `tmp/lineup-graphics/{slug}-frames/`, writes actual capture FPS to `framerate.txt`. Then `LineupGraphic::AssembleVideo` runs ffmpeg with the recorded input rate, downsamples + caps output at 30fps. **Critical**: X's video spec is ≤60fps; CDP delivers 60–80fps in practice → without the fps=30 filter, /tweets rejects with "Your media IDs are invalid".

### `X::PostMedia` notes
v2 chunked upload at `api.x.com/2/media/upload/{initialize,<id>/append,<id>/finalize}` with a `?command=STATUS` read, then v2 post creation at `api.x.com/2/tweets`. X sunset the v1.1 upload host (`upload.twitter.com/1.1/media/upload.json`) on 2025-06-09; the uploader moved to v2 on 2026-10-04. Uses `X::OAuthSigner` (HMAC-SHA1, OAuth 1.0a user context) and `X::Client` (Net::HTTP). Includes a 3s propagation buffer after STATUS=succeeded and a single auto-retry on 400 "media IDs are invalid" (cache lag between upload backend and tweet endpoint). OAuth signature rule: form-urlencoded bodies and query params are signed; multipart, JSON and empty bodies sign only `oauth_*` params. The API is billed per call. `bin/x-post` posts one LOCAL MP4 through the same uploader with no Content record, for the Turf Monster `post-to-x` SOP; `X::Caption` measures a caption by X's weighted count.

### Rake
`bin/rails lineup_graphic:capture SLUG=buffalo-bills` runs the capture script + `LineupGraphic::AssembleVideo` for local testing without going through a Content record.

## Video Post (X) Workflow

`Content.workflow = "video_post_x"` is an input-output machine: the operator gives the team that won and an MP4, and the card produces an approved post on `@turfmonstershow`. It is the board half of the Turf Monster `post-to-x` SOP; `bin/x-post` is the same machine from the command line.

| Stage | Means | How it gets there |
|---|---|---|
| `idea` | Video stored, no copy | Create, when the draft could not be read |
| `script` | Copy drafted, waiting on the operator's click | Create (normally), Redraft, or a refused post |
| `assembly` | A post is in flight, or one started and never reported back | The Post button |
| `posted` | Live, with its link | The job, the settle form, or the agent API |

1. **Create**: `/contents/new` → **Video Post (X)** → team + MP4. `ContentsController#create_video_post_x` checks the file and the team BEFORE saving (`Content::AttachVideo#validate!`: an `.mp4` with `video/mp4`, at most 100 MB), saves, stores the file at `video_posts/<slug>.mp4` OUTSIDE a transaction (destroying the card if the upload raises), then runs `Content::DraftXCopy`. A server killed mid-upload can leave a card with no `final_video_url`; `Content.claimable_by_agent` excludes it.
2. **Draft**: `X::PostDraft` (pure Ruby, shared with `bin/x-post draft`) reads three ESPN documents through `Espn::Api`'s host: the team list (matched by display name, so no abbreviation map), the team's record, and its schedule. Copy is `<mascot> <record>` plus `#nfl #nflfootball`, the team's `hashtag`, the city, the mascot and a prime-time slot tag. It returns the facts it read and a list of exceptions (latest final was a loss, final older than eight days, no slogan tag). `DraftXCopy` stores the text in `captions` and the facts in `game_facts`.
3. **Preview**: `contents/_video_post_x_card` renders `contents/_x_post_preview`, the post as X draws it. Its colours are X's and are inline on purpose, so the picture is the same in our light and dark themes. `x_post_markup` escapes the copy before colouring tags.
4. **Post**: `Content::PostVideoToX.begin!` refuses anything unpostable (`refusal` names the reason and also drives the disabled button), moves the card to `assembly` with `game_facts["post"]["state"] = "queued"`, and enqueues `ContentPostVideoToXJob`. The job moves `queued → posting` under a row lock and posts only if it made that move, so a re-delivered job cannot post twice. Outcomes: `posted` (link recorded, then `X::ReadBack` confirms the video attached); `refused` (X answered and nothing is live — `X::PostMedia::NotPosted` — card back to `script`); `unknown` (anything else — card stays in `assembly` and asks the operator to look at the timeline). `ApplicationJob` retries by default; this job discards instead.
5. **Settle**: `resolve_x_post` takes the operator's answer for a stuck card: a pasted link, or "it is not there".

The button is disabled, with the reason beside it, unless the server holds `X_API_KEY`/`X_API_SECRET`/`X_ACCESS_TOKEN`/`X_ACCESS_TOKEN_SECRET`.

Agent API: `POST /api/v1/contents/:slug/posted` records a link on a claimed card; `POST /api/v1/contents/record_x_post` files a `posted` card for a video posted from a file path (`bin/content record-post`), idempotent on the link.

The e2e lane has no bucket and must not depend on a live feed, so `config/initializers/e2e_video_storage.rb` replaces `Content::AttachVideo.store` and `Content::DraftXCopy.fetch` when the Playwright server sets `E2E_FAKE_VIDEO_STORAGE=1`.

## Starter Post (TikTok) Workflow

`Content.workflow = "starter_post_tiktok_offense"` and `"starter_post_tiktok_defense"`. Two workflows, one per side of the ball, that mirror the X pipeline but post 19-second vertical (1080×1920) clips to TikTok. **Posting is currently a creator-copilot loop**: agent does all prep, human does the publish click. Three publish paths exist (API drafts, API direct, manual fallback) but TikTok app is in review until Content Posting API approval lands — only sandbox-mode + manual paths work for now.

### Pipeline
`script` → [Generate Assets] → `assets` → [✨ Prep for Post] → `assembly` → [🚀 Begin Post or 🤖 Auto-Upload] → human posts → [Mark Posted] → `posted`.

### Routes
`POST /contents/starter_post_tiktok_offense?team_slug=...` + `POST /contents/starter_post_tiktok_defense?team_slug=...` (create at stage=script). Member: `prep_for_tiktok` (assets→assembly), `use_caption_variant` (swap captions to a variant), `mark_posted` (advances to posted, URL optional), `studio_upload_to_tiktok` (Playwright auto-upload, dev-only), `post_to_tiktok` (API direct/inbox).

### Lineup graphic page (TikTok variants)
`GET /teams/:slug/lineup-graphic` controlled by query params:
- `?side=offense` — renders `app/views/lineup_graphics/offense.html.erb` (5×2 grid: row 1 LT, LG, C, RG, RT; row 2 QB, RB, WR1, WR2, TE). No header.
- `?side=defense` — renders `app/views/lineup_graphics/defense.html.erb` (3×3 grid: row 1 EG1, DL1, EG2; row 2 LB1, LB2, SS; row 3 FS, CB1, CB2). No header.
- No `side` param → existing full graphic (X workflow, header included, 12+12+4 grid).
- **Note**: these are real view templates (no underscore), not partials. `render "offense"` from controller resolves to `offense.html.erb`. Shared bits live in `_tile_xl.html.erb`.

### Reveal animation matrix (URL-selectable so we can A/B without rebuild)
- Offense (`?reveal=hike|spotlight|domino`, default `hike`)
  - `hike` — OL row flips L→R first, then C "snaps" a glowing pulse backward to QB, skill players reveal radially outward from QB.
  - `spotlight` — single bright vertical sweep moves L→R, illuminating each card as it passes (QB pre-snap-read vibe).
  - `domino` — cards drop in from above with a bounce, L→R top-to-bottom.
- Defense (`?reveal=heat|blitz|crack`, default `heat`)
  - `heat` — red thermal targeting reticle locks onto each card before flip, pulses outward in heat-vision red.
  - `blitz` — diagonal red scanline sweeps in attack-pattern order (front 3 → LBs → secondary).
  - `crack` — each card "shatters into view" with a glass-crack overlay that fades out post-reveal.
- `?pace=N` — milliseconds between reveals (default 1700; 1500 for offense gives ~19s clip).

### Capture script (TikTok)
`script/capture_lineup.js` accepts SIDE/REVEAL/PACE env vars. SIDE=full uses 1200×1500 viewport (X), SIDE=offense|defense uses 1080×1920 (TikTok 9:16). Output paths embed side: `tmp/lineup-graphics/{slug}-{side}-frames/`, `tmp/lineup-graphics/{slug}-{side}.{png,mp4}`. REVEAL_TIMEOUT_MS bumped to 45s for the longer clips.

### Asset generation
`Content::GenerateLineupAssets` dispatches by workflow: `starter_post_x` → side=full, `starter_post_tiktok_offense` → side=offense, `starter_post_tiktok_defense` → side=defense. S3 path: `tiktok_posts/{team_slug}/{content_slug}_{side}.{png,mp4}` for TikTok, `starter_posts/{team_slug}/{content_slug}.{png,mp4}` for X. `LineupGraphic::AssembleVideo` is now side-aware (different output dimensions per side via `DIMENSIONS` map) and accepts optional `music_path:` for ffmpeg audio mux.

### Captions (auto-populated on create, editable on edit page)
- Offense: `"Find the mistake on my {Mascot} OFFENSE 🚨"`
- Defense: `"Find the mistake on my {Mascot} DEFENSE 🛡️"`

### Creator copilot — `Content::PrepForTiktok`
Runs at stage=assets, calls Anthropic Haiku with side-aware prompts ("smooth operation, who's the imposter" for offense; "chaos, blitz, find the weak link" for defense). Generates 3 hooky caption variants (varied angles: question hook / hot take / callout), 3 plain-English music vibe descriptors (NOT real track names — creator searches TikTok's full trending library), 8-12 hashtags. Stores in new `caption_variants` jsonb column + existing `hashtags` + `music_suggestions`, advances stage assets→assembly. The vibe-not-track-name choice is deliberate: real trending sounds change weekly and aren't accessible via API anyway.

### Assembly stage UI
Extracted to `app/views/contents/_tiktok_assembly_card.html.erb`. Autoplay video preview, 3 caption variants with radio + "Use this" buttons (calls `use_caption_variant`), music vibe list, hashtag display, three handoff paths:
1. **🚀 Begin Post** (always visible) — single click does three things: copies caption+hashtags to clipboard, triggers MP4 download via injected anchor, opens TikTok Studio in new tab. User drags MP4 in, pastes caption, picks sound, clicks Post.
2. **🤖 Auto-Upload** (dev-only) — `Tiktok::StudioUpload` spawns `script/post_to_tiktok.js` as a detached subprocess. Playwright launches non-headless Chromium with `userDataDir = ~/.tiktok-bot-profile/`, navigates to TikTok Studio, sets MP4 via file input, types caption, prints sound vibe to console, leaves browser open. User reviews + clicks Post. One-time setup: `npm run tiktok:login` (runs `script/tiktok_login.js`).
3. **Mark Posted** — paste TikTok URL OR click with no URL (escape hatch — paste later via Edit). Both advance stage to posted.

### TikTok API posting (in app review)
`Tiktok::OAuthClient` (refresh-token flow) + `Tiktok::PostMedia` (Content Posting API, `PULL_FROM_URL` pointed at the S3 MP4). `Content::PostToTiktok` orchestrates. Two endpoints: `inbox` (drafts, recommended for trend-chasing) and `direct_post` (immediate publish, optional CML music_id). ENV: `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET`, `TIKTOK_REFRESH_TOKEN`, `TIKTOK_OPEN_ID`. 1Password item: `🐊 TikTok` in the `studio-agents` vault (not present there on 2026-08-29 — recreate it before relying on this step). **One-time OAuth handshake**: visit `/admin/tiktok/connect`, authenticate as @turfmonstershow, copy the displayed `TIKTOK_REFRESH_TOKEN` + `TIKTOK_OPEN_ID` into `.env` and back into 1Password.

### TikTok app status
Submitted for review 2026-05-04. Sandbox mode works for the app owner's account. App scopes were initially over-requested (Login Kit + Content Posting API + Share Kit + Data Portability + Webhooks + Local Service API); for production approval should be trimmed to just Login Kit + Content Posting API with scopes user.info.basic + video.upload + video.publish.

### TikTok app registration
- Redirect URI: `https://mcritchie.studio/admin/tiktok/callback` after root-domain launch. Keep `https://app.mcritchie.studio/admin/tiktok/callback` registered as a legacy callback until provider dashboards are fully updated.
- Terms of Service: `https://mcritchie.studio/terms`
- Privacy Policy: `https://mcritchie.studio/privacy`
- Domain verification: signature file at `public/tiktokHckWWupyGeHg0pg5QM7ApgceP3z1jwB9.txt` (URL prefix verification should be updated from `https://app.mcritchie.studio/` to `https://mcritchie.studio/` during launch)

### Music
Three options: (A) trending sound — only via human in TikTok Studio/app since TikTok's full library isn't API-accessible; (B) Commercial Music Library — `music_id` param on direct_post, requires TikTok Business account; (C) royalty-free baked in — `LineupGraphic::AssembleVideo` accepts `music_path:` to mux audio at render time. Default user flow uses (A) via the assembly card.

### Form gotcha
When adding new workflow values to `Content::WORKFLOWS`, also add them to the `<select>` in `app/views/contents/_form.html.erb`. Otherwise the edit form silently falls back to "video" on save and wipes the workflow.

### Heroku LFS gotcha (break-glass pushes only)
Production never deploys by hand push; `bin/release ship` dispatches `prod-deploy.yml` ([How Production Deploys](../agents/modules/deployment.md#how-production-deploys)). If an emergency forces a manual push anyway: the repo has LFS pointers in history (retired 2026-04-30) but Heroku's git remote doesn't speak LFS, so push with `--no-verify` to skip the LFS pre-push hook. Push an explicit SHA rather than a local branch that may lag `origin/main` — `git push heroku <sha>:refs/heads/main --no-verify`, the ref shape the workflow pushes. A hand push skips the G4 gate and the release record.
