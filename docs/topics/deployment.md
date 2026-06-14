# Deployment

> **When to read this:** Standing up dev, configuring Heroku, adding/rotating env vars, or modifying the tech stack.

## Dev Server

- **Port 3000** — `bin/rails server` (default)
- Turf Monster runs on port 3100
- Tax Studio is planned on port 3200

## Deployment

- **Heroku app**: `mcritchie-studio`
- **URL**: https://app.mcritchie.studio
- **Heroku URL**: https://mcritchie-studio-039470649719.herokuapp.com/
- **Database**: Heroku Postgres (essential-0)
- **DNS**: Google Domains — `app` CNAME → Heroku DNS target
- **Deploy**: `git push heroku main` (then `heroku run bin/rails db:migrate --app mcritchie-studio` if new migrations)
- **Env vars**: `RAILS_MASTER_KEY`, `RAILS_SERVE_STATIC_FILES`, `DATABASE_URL` (auto), `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `ANTHROPIC_API_KEY` (for AI chat + content script/metadata agents), `X_BEARER_TOKEN` (read-only, News intake), `X_API_KEY`/`X_API_SECRET`/`X_ACCESS_TOKEN`/`X_ACCESS_TOKEN_SECRET` (OAuth 1.0a write creds for `X::PostMedia` — must be from an X app with "Read and Write" permissions), `HIGGSFIELD_API_KEY`, `HIGGSFIELD_API_SECRET` (for content image/video generation via Nano Banana + Kling 3 — 1Password item `agent.higgesfield` in `agents` vault)
- **ACM**: Enabled (auto SSL via Let's Encrypt)

## Public Assets

- `public/agents/` — Agent avatar images (alex.png, alex-photo.png, mack.png, mason.png, turf-monster.png)
- `public/denver-hero.avif` — Landing page hero background (Denver skyline)
- `public/studio-logo.svg` — SSO logo (shared with satellite apps)
- `public/favicon.png`, `public/icon.png`, `public/logo-icon.svg` — App icons

## Tech Stack

- Ruby 3.1 / Rails 7.2 / PostgreSQL
- Tailwind CSS via `tailwindcss-rails` gem (compiled with `@apply` support, not CDN)
- Alpine.js via CDN for interactivity
- Montserrat font (Google Fonts CDN)
- ERB views, import maps, no JS frameworks
- Passwordless auth via magic links, Google OAuth, and Solana wallet. `has_secure_password` remains on `User` only as a dormant compatibility fallback.
- Email delivery uses `Studio::Email` with SES as the target transport and Resend as rollback. Cross-app operations live in `docs/agents/modules/email-operations.md`; McRitchie-specific wiring lives in `docs/email-delivery.md`.
- **Studio engine gem** — `gem "studio-engine", "~> 0.5"` from RubyGems; release/adoption checklist lives in `studio-engine/docs/RELEASE.md`
