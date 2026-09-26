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
| Finding more | `Appearances::ImageSearch` (façade) + `::Serper` (provider) |
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
it, because it already took the list as an injection. Read "waiting on a search"
as "waiting on `SERPER_API_KEY`", never as "waiting on code".

**Where the found photographs live.** `appearance_reference_photos` holds EVERY
candidate a search returned, chosen or not, with the reason each was passed over
(`unfetchable` / `duplicate` / `beyond_limit`) and the query that found it. The
rejects are kept on purpose: the operator's question is "is the search any good?",
and a table of winners cannot answer it — a search returning twenty stock
thumbnails yields the same single winner as one returning twenty good portraits we
capped at `GatherReferencePhotos::CHOSEN_LIMIT`. `ImageCache` is NOT the home for
these: it is unique on `variant` per (owner, purpose) and demands an `s3_key`, so
filing a reject would mean paying to mirror a photograph we had already refused.

**The provider is an interface, and it does not assume a credential.** A provider
answers `provider_name`, `available?` and `search(query:, limit:)`, and
`available?` is asked OF THE PROVIDER — so a keyless source (Wikimedia Commons
answers image queries with no key) plugs in without the façade changing. Serper.dev
is the only provider that ships. **Its response shape is UNVERIFIED**: no
credential exists, so the parser reads `imageUrl` alone and treats every other
field as optional, skipping and COUNTING rows it cannot read. When the key lands,
probe once, capture the body, and replace the `assumed_serper_body` fixture in
`test/services/appearances/image_search/serper_test.rb` — a green test over a
guessed fixture proves the guess is self-consistent and nothing more.

**No key is a clean degrade, not an error.** With nothing configured the page
renders from the headshot floor, offers no Search button, and names
`SERPER_API_KEY` in the note — because the reader of that note is who will set it.

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

The classifier is asked once per search with every shortlisted image in ONE
message (`GatherReferencePhotos::VISION_SHORTLIST`, currently 12), and Anthropic
fetches the images server-side from a `type: "url"` source — the same trust
boundary Higgsfield's create sits behind, and the same obligation: only URLs that
have cleared `Appearances::FetchableUrl` are ever passed.

**Prioritise, never starve.** A helmeted photograph still goes into the identity
when nothing better exists — measured on a real Commons answer for "Drew Lock",
exactly ONE of twenty hits was bare-faced. The one HARD exclusion is
`not_a_photo`: a scanned book page or a diagram, which is not a poor reference but
no reference at all. Documents are also never sent to the classifier — measured on
that same answer, 12 of the 20 candidates were documents, so the paid shortlist
drops from 12 images to 8. That rule exists because of a real defect — with a blind
take-the-top-N, an 1896 edition of *The Rape of the Lock* was selected into a
character model.

**⚠ The classifier is UNVERIFIED end to end.** No `ANTHROPIC_API_KEY` exists on
any machine or in any readable vault, so it has never been driven against the live
API. Its request shape comes from the documented Messages API, not from an
observed 200. First job the day a key lands: one real call, then pin the real
response body as a fixture in `test/services/appearances/face_visibility_test.rb`.

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
`Net::HTTP` call to `api.anthropic.com` keyed on `ENV["ANTHROPIC_API_KEY"]` —
which **production does not have**. Routing inference through a soul instead
means no model key in prod, prompts that live in SOP prose an agent can improve
rather than frozen string literals in `.rb` files, inference that lands in the
agent trajectory where the learning loop can grade it, and a real voice veto
(Mason cannot veto a line a Rails service already sent). Those services stay in
place as the LEGACY path for `workflow=video`; retiring them is its own task.

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
   - **Auto** — `POST /contents/:slug/post_to_x` → `Content::PostToX` downloads MP4 from S3 → `X::PostMedia` (v1.1 chunked upload + v2 /tweets) → records `post_url`/`post_id`/`posted_at`, stage=`posted`. Disabled if any of `X_API_KEY`/`X_API_SECRET`/`X_ACCESS_TOKEN`/`X_ACCESS_TOKEN_SECRET` are missing.
   - **Manual** — "⬇ Download Video" + "📤 Open X Compose" (intent URL with caption pre-filled, attach video by hand) + paste-URL form → `post_step` extracts post_id from `/status/(\d+)` and saves.

### Schema additions
- **`Content` columns added**: `workflow` (string, default `"video"`, validated against `Content::WORKFLOWS`), `team_slug` (FK → Team).
- **Team metadata columns** — `hashtag` (32/32), `hashtag2` (8/32 — secondary tag for richer captions), `x_handle` (19/32 — for `@`-mentions). Seeded for all 32 NFL teams from `db/seeds/data/teams_hashtags.csv` via `bin/rails teams:backfill_metadata` (also wired into `db:seed` as `13_team_metadata.rb`).

### Lineup graphic page
`GET /teams/:slug/lineup-graphic` (`LineupGraphicsController#show`) renders a 1200×1500 social asset: header → Offense (4×3) | Defense (4×3) side-by-side → Special Teams. Uses its own bare layout `layouts/lineup_graphic.html.erb` (no nav, no Tailwind — inline CSS so screencaps are deterministic). JS exposes `window.startLineupReveals()` so the capture script triggers the reveal cascade only after CDP screencast is live. Reveal cadence is 200ms per tile; 28 tiles total (12 off + 12 def + 4 ST). Auto-starts after 1500ms for human visitors.

### Capture pipeline
`script/capture_lineup.js` uses Playwright + Chrome DevTools Protocol `Page.startScreencast` at 2x device pixels (2400×3000 frames), saves PNG sequence to `tmp/lineup-graphics/{slug}-frames/`, writes actual capture FPS to `framerate.txt`. Then `LineupGraphic::AssembleVideo` runs ffmpeg with the recorded input rate, downsamples + caps output at 30fps. **Critical**: X's video spec is ≤60fps; CDP delivers 60–80fps in practice → without the fps=30 filter, /tweets rejects with "Your media IDs are invalid".

### `X::PostMedia` notes
v1.1 chunked upload at `upload.twitter.com/1.1/media/upload.json` + v2 tweet creation at `api.twitter.com/2/tweets`. v2 chunked upload is Pro-tier only; v1.1 is the Free-tier path. Uses `X::OAuthSigner` (HMAC-SHA1) and `X::Client` (Net::HTTP). Includes a 3s propagation buffer after STATUS=succeeded and a single auto-retry on 400 "media IDs are invalid" (cache lag between upload backend and tweet endpoint). OAuth signature rule: form-urlencoded bodies sign body fields, multipart/form-data and JSON bodies sign only `oauth_*` params.

### Rake
`bin/rails lineup_graphic:capture SLUG=buffalo-bills` runs the capture script + `LineupGraphic::AssembleVideo` for local testing without going through a Content record.

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
