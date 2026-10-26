# Deployment

> **When to read this:** Standing up dev, configuring Heroku, adding/rotating env vars, or modifying the tech stack.

## Dev Server

- **Port 3000** — `bin/rails server` (default)
- Turf Monster runs on port 3100
- Tax Studio is planned on port 3200
- Rolio is reserved on port 3300
- Chain Ops is planned on port 3400

## Deployment

- **Heroku app**: `mcritchie-studio`
- **URL**: https://mcritchie.studio
- **Legacy URL**: https://app.mcritchie.studio
- **Archive URL**: https://v1.mcritchie.studio for the previous Squarespace site
- **Heroku URL**: https://mcritchie-studio-039470649719.herokuapp.com/
- **Database**: Heroku Postgres (essential-1, 20 connections)
- **DNS**: apex `mcritchie.studio` ALIAS/ANAME → Heroku DNS target;
  `www` CNAME → Heroku DNS target; `app` CNAME remains as a legacy alias;
  `v1` CNAME remains attached to Squarespace
- **Deploy**: `bin/release ship` dispatches `.github/workflows/prod-deploy.yml`
  with the frozen SHA — not `git push heroku main`. The Heroku `release` process
  runs `bin/rails db:migrate` before promotion. Full path:
  [How Production Deploys](../agents/modules/deployment.md#how-production-deploys).
- **Workers**: keep `worker=1` scaled for Solid Queue mail/auth job durability.
- **Env vars**: `RAILS_MASTER_KEY`, `RAILS_SERVE_STATIC_FILES`, `DATABASE_URL` (auto), `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `ANTHROPIC_API_KEY` (for AI chat + content script/metadata agents), `X_BEARER_TOKEN` (read-only, News intake), `X_API_KEY`/`X_API_SECRET`/`X_ACCESS_TOKEN`/`X_ACCESS_TOKEN_SECRET` (OAuth 1.0a write creds for `X::PostMedia` — must be from an X app with "Read and Write" permissions), `HIGGSFIELD_API_KEY`, `HIGGSFIELD_API_SECRET` (for content image/video generation via Nano Banana + Kling 3 — 1Password item `higgsfield.studio.agents` in the `studio-agents` vault)
- **TLS**: Heroku ACM is **disabled** on `mcritchie-studio` (the `*.mcritchie.app` origin certificate turned it off; Heroku allows one or the other per app). The hub's names are moving to Cloudflare origin certificates behind a proxied record, Full (strict): state, expiry dates and rollback in [Certificates and the Edge](../agents/modules/deployment.md#certificates-and-the-edge)

## Root-Domain Launch Status

As of 2026-06-15, `mcritchie.studio` is the canonical production host.
Production config should keep `APP_HOST=mcritchie.studio` and
`MAILER_HOST=mcritchie.studio`; `APP_HOST_ALIASES` should include
`app.mcritchie.studio`, `www.mcritchie.studio`, and the Heroku fallback host.
Their certificates were ACM-issued and no longer renew (see [Certificates and the Edge](../agents/modules/deployment.md#certificates-and-the-edge)). The two aliases
answer only to hand visitors on: `CanonicalHost`
(`lib/middleware/canonical_host.rb`) 301s every GET and HEAD on them to
`APP_HOST`, and the Google OAuth callback is pinned to the same host, so a
sign-in begun on an alias no longer draws `redirect_uri_mismatch`. `/up`,
requests other than GET and HEAD, and `DYNO_HOST` stay reachable under their
own names.
`v1.mcritchie.studio` is connected to the old Squarespace site as its primary
domain, has the Squarespace `www` prefix disabled, and returns `200`.

Use public DNS when checking propagation because local routers may cache the old
Squarespace records for up to the previous 4-hour TTL:

```bash
dig +short @1.1.1.1 mcritchie.studio A
dig +short @1.1.1.1 www.mcritchie.studio CNAME
dig +short @1.1.1.1 v1.mcritchie.studio CNAME
curl -I https://mcritchie.studio/up
curl -I https://www.mcritchie.studio/up
curl -I https://app.mcritchie.studio/up
```

`v1.mcritchie.studio` is the Squarespace archive. If it regresses to a browser
privacy error or redirects to `www.mcritchie.studio`, verify the Squarespace
site connection, primary-domain setting, disabled `www` prefix, and
`ext-cust.squarespace.com` DNS target.

## Public Assets

- `public/agents/` — Agent portraits, one per seeded agent; each agent's `avatar`
  in `db/seeds/02_agents.rb` names its file, and `test/models/agents_seed_test.rb`
  checks that every one is on disk. They serve as both the circular avatar and the
  full-bleed 5:3 card hero on the public `/agents` index;
  `test/lib/response_payload_budget_test.rb` holds their byte budget and size limits.
- `app/assets/images/hero/` — the landing page hero (Denver skyline), served through a `<picture>` in `app/views/landing/index.html.erb`: the panorama at 1280, 1920 and 2560 wide, and a centre 1260 × 1800 portrait crop at 390, 768 and 1260 for phones. They are fingerprinted assets, so they cache for a year. The 4700 × 1800 master (1.6MB) is no longer in the slug; recover it from git with `git show "$(git log -1 --format=%H --diff-filter=D -- public/denver-hero.avif)^:public/denver-hero.avif" > /tmp/denver-hero.avif` (or use a new photo) and regenerate with ImageMagick at AVIF quality 45:
  `magick /tmp/denver-hero.avif -resize 1920x -strip -quality 45 app/assets/images/hero/denver-hero-1920.avif` (and 1280, 2560), and
  `magick /tmp/denver-hero.avif -gravity center -crop 1260x1800+0+0 +repage -resize 390x -strip -quality 45 app/assets/images/hero/denver-hero-portrait-390.avif` (and 768, 1260).
- `public/brand/` — the saved Studio kit's files (`icon-*`, `navbar-*`, `stacked-*` in light, dark and watermark, plus `kit.json`), written by `bin/rails logos:install BRAND=studio`; the navbar, footer, sign-in card and SSO logo draw from it ([`logos.md`](logos.md#installing-a-kit-into-an-app))
- `public/favicon.png`, `public/icon.png` — favicon and PWA icon, rasterized from `public/brand/icon-dark.svg` by `script/brand_png.cjs`: the favicon edge to edge (the icon's box is its ink), the PWA icon with a 0.16 safe zone on every edge, because the manifest serves it as `"purpose": "maskable"` (`node script/brand_png.cjs public/brand/icon-dark.svg public/icon.png 512 '#1A1535' 0.16`)
- `public/og.png` — the last-resort link preview image (1200 × 630): `public/brand/stacked-dark.svg` centred on `#1A1535`, regenerated with the ImageMagick command in [`logos.md`](logos.md) after a kit change; an image uploaded at `/admin/link_preview` outranks it
- `public/studio-logo.svg` — the old chest artwork, now only the (stub) video watermark in `Content::Finalize`
- `public/logo-icon.svg` — the old white chest, no longer drawn by the hub; kept so links to it in sent mail still resolve

## Asset pipeline (Propshaft)

The hub serves its assets through **Propshaft** with **importmap-rails**; Sprockets
was removed on 2026-10-25 (task `hub-moves-to-propshaft`, recipe in rolio's
`docs/RUNBOOK.md`, "Asset pipeline (Propshaft)"). Every file under `app/assets/*`
(except `app/assets/tailwind`, which tailwindcss-rails keeps off the load path),
`app/javascript`, `vendor/javascript` and each engine's asset directories is
served at `/assets/<name>-<8-hex digest>.<ext>`. There is no `manifest.js` and no
`*= require` directive; a new stylesheet is linked from the layout.

- `app/assets/stylesheets/application.css` holds no rules but must stay: the
  engine head (`layouts/studio/_head.html.erb`) links `"tailwind"` and
  `"application"` by name, and Propshaft raises at render on a missing one.
- Precompile: `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile`
  (a local run also needs the four `R2_*` names set to any value; the storage
  initializer refuses a production boot without them). It writes
  `public/assets/.manifest.json`, the digested files, and a `.gz` beside every
  digested css, js and svg (`lib/precompressed_assets.rb`, hooked in
  `lib/tasks/precompressed_assets.rake`). Propshaft writes no `.gz` itself, and
  Rack::Deflater never reaches a static file (`config/application.rb`), so those
  sidecars are what production sends compressed.
- Fingerprinted `/assets/*` cache for a year (`lib/middleware/digested_asset_cache.rb`,
  eight or more hex digits); everything else under `public/` keeps the week.
- AVIF is registered in `config/initializers/assets.rb`: Rails' Mime registry has
  no AVIF type, and Propshaft types an asset from it.
- Nothing under `public/assets` is tracked, so `bin/rails assets:clobber` is safe.
  It also deletes `app/assets/builds/tailwind.css`; rebuild with
  `bin/rails tailwindcss:build`. While a `.manifest.json` sits in `public/assets`,
  dev and test serve the precompiled copies, not your edits.
- Guards: `test/lib/asset_pipeline_test.rb` (Sprockets, its manifest, directives
  or Sprockets-only `config.assets.*` coming back; AVIF typing) and
  `test/integration/asset_urls_test.rb` (every `/assets` URL on the main pages,
  signed out and in, and every importmap pin, the engine's included, resolves
  fingerprinted with a 200).

## Tech Stack

- Ruby 3.3.11 / Node 22.x / Rails 8.1 / PostgreSQL
- Tailwind CSS via `tailwindcss-rails` gem (compiled with `@apply` support, not CDN)
- Alpine.js via CDN for interactivity
- Montserrat font (Google Fonts CDN)
- ERB views, import maps, no JS frameworks
- Passwordless auth via magic links and Google OAuth. `User` has no `has_secure_password` and stores no password.
- Email delivery uses `Studio::Email` on Resend; the SES transport was removed in studio-engine 0.102.0 when SES was retired (2026-10-10). Cross-app operations live in `docs/agents/modules/email-operations.md`; McRitchie-specific wiring lives in `docs/email-delivery.md`.
- **Studio engine gem** — `gem "studio-engine", "~> 0.11"` from RubyGems; release/adoption checklist lives in `studio-engine/docs/RELEASE.md`
