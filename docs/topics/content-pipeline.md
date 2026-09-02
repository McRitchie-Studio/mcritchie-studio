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
- `Higgsfield::Client` — Shared HTTP client (`app/services/higgsfield/client.rb`). Auth via `hf-api-key`/`hf-secret` headers. Submit + poll pattern with 5-min timeout.

## Rake Tasks

`content:hook`, `content:script`, `content:assets`, `content:assemble`, `content:post`, `content:review` (manual). `content:script_agent`, `content:assets_agent`, `content:assemble_agent`, `content:finalize`, `content:metadata` (AI). `content:generate SLUG=xxx` (full pipeline). All support `SLUG=` override.

**Feature status: ON ICE** — Services are built and wired up but not yet tested end-to-end with real API calls.

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

### Heroku LFS gotcha
Repo has LFS pointers in history (retired 2026-04-30) but Heroku's git remote doesn't speak LFS. Push with `git push heroku main --no-verify` to skip the LFS pre-push hook.
