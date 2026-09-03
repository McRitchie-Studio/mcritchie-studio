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
- **Database**: Heroku Postgres (essential-0)
- **DNS**: apex `mcritchie.studio` ALIAS/ANAME → Heroku DNS target;
  `www` CNAME → Heroku DNS target; `app` CNAME remains as a legacy alias;
  `v1` CNAME remains attached to Squarespace
- **Deploy**: `git push heroku main`; the Heroku `release` process runs
  `bin/rails db:migrate` before promotion.
- **Workers**: keep `worker=1` scaled for Solid Queue mail/auth job durability.
- **Env vars**: `RAILS_MASTER_KEY`, `RAILS_SERVE_STATIC_FILES`, `DATABASE_URL` (auto), `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `ANTHROPIC_API_KEY` (for AI chat + content script/metadata agents), `X_BEARER_TOKEN` (read-only, News intake), `X_API_KEY`/`X_API_SECRET`/`X_ACCESS_TOKEN`/`X_ACCESS_TOKEN_SECRET` (OAuth 1.0a write creds for `X::PostMedia` — must be from an X app with "Read and Write" permissions), `HIGGSFIELD_API_KEY`, `HIGGSFIELD_API_SECRET` (for content image/video generation via Nano Banana + Kling 3 — 1Password item `agent.higgesfield` in the `studio-agents` vault)
- **ACM**: Enabled (auto SSL via Let's Encrypt)

## Root-Domain Launch Status

As of 2026-06-15, `mcritchie.studio` is the canonical production host.
Production config should keep `APP_HOST=mcritchie.studio` and
`MAILER_HOST=mcritchie.studio`; `APP_HOST_ALIASES` should include
`app.mcritchie.studio`, `www.mcritchie.studio`, and the Heroku fallback host.
Heroku ACM has issued certs for root, `www`, and legacy `app`.
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

- `public/agents/<slug>.webp` — Agent portraits, one per seeded agent (alex, avi, carl,
  jasper, mack, mason, shannon, steffon, turf-monster), plus the landing-page headshot
  `public/agents/alex-photo.webp`. They serve as both the circular avatar and the
  full-bleed 5:3 card hero on the public `/agents` index, so the long edge is capped at
  768px: the seven 5:3 heroes are 768x461 and `turf-monster.webp` is 768x768. The two
  square files stay smaller for their own reasons — `alex.webp` (340x340) has no committed
  source above 512px, and `alex-photo.webp` (192x192) was cut down from 420x420 because the
  landing page draws it at `w-16` (64px). `test/lib/response_payload_budget_test.rb` holds
  the byte budget, that 768px ceiling, and a 640px floor scoped to the 5:3 heroes, so
  neither square file trips it; `test/docs/agent_portrait_extension_docs_test.rb`
  keeps this bullet honest about the container.
- `public/denver-hero.avif` — Landing page hero background (Denver skyline)
- `public/studio-logo.svg` — SSO logo (shared with satellite apps)
- `public/favicon.png`, `public/icon.png`, `public/logo-icon.svg` — App icons

## Tech Stack

- Ruby 3.3.11 / Node 22.x / Rails 8.1 / PostgreSQL
- Tailwind CSS via `tailwindcss-rails` gem (compiled with `@apply` support, not CDN)
- Alpine.js via CDN for interactivity
- Montserrat font (Google Fonts CDN)
- ERB views, import maps, no JS frameworks
- Passwordless auth via magic links, Google OAuth, and Solana wallet. `has_secure_password` remains on `User` only as a dormant compatibility fallback.
- Email delivery uses `Studio::Email` with SES as the target transport and Resend as rollback. Cross-app operations live in `docs/agents/modules/email-operations.md`; McRitchie-specific wiring lives in `docs/email-delivery.md`.
- **Studio engine gem** — `gem "studio-engine", "~> 0.11"` from RubyGems; release/adoption checklist lives in `studio-engine/docs/RELEASE.md`
