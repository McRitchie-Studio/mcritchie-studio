# McRitchie Studio

Task management and orchestration hub for the McRitchie AI agent system. McRitchie Studio is also the documentation anchor for the full local development stack: if the machine is wiped, this repo is the first clone and the source of truth for rebuilding the ecosystem.

**Live**: https://app.mcritchie.studio

McRitchie Studio is the **flagship app** of the McRitchie ecosystem ([turf-monster](https://github.com/amcritchie/turf-monster), [studio-engine](https://github.com/amcritchie/studio-engine), [solana-studio](https://github.com/amcritchie/solana-studio), [turf-vault](https://github.com/amcritchie/turf-vault), and future apps). Clone this repo first; it carries the scripts and agent-neutral docs that bootstrap everything else.

> **New here?** Read [`docs/ECOSYSTEM.md`](docs/ECOSYSTEM.md) first — it's the canonical 2-minute orientation surface for the ecosystem.

> **Agent session?** Run `bin/install-agent-docs` after cloning or pulling this repo. It refreshes `/Users/alex/projects/AGENTS.md` from the tracked source at [`docs/agents/index.md`](docs/agents/index.md), then prints the next context files to read. Use `bin/install-agent-docs check` to detect drift.

---

## Fresh-Mac ecosystem recovery (the canonical path)

Use this when standing up a brand new machine, or anytime you want to confirm "everything still works." Idempotent — safe to re-run.

**One-time prereqs** (NOT auto-installed):
- macOS with Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh)
- A 1Password service account token with **read** access to the `agents` vault (account `alex@mcritchie.studio`). Generate at https://start.1password.com → Developer Tools → Service Accounts.

```bash
# 1. Clone the flagship — every other repo + script lives downstream of this one.
git clone https://github.com/amcritchie/mcritchie-studio.git ~/projects/mcritchie-studio
cd ~/projects/mcritchie-studio

# 2. First pass — installs every brew package (incl. 1Password CLI), Rust, Solana,
#    Anchor, etc. Bails at Phase 4 once it needs your 1Password service token.
bin/ecosystem-build

# 3. Copy your 1Password service account token (ops_...) to clipboard, then:
bin/setup-1pass-token

# 4. Second pass — picks up at Phase 4, pulls Heroku key + .env, clones the
#    other 4 repos, installs the projects-level AGENTS.md, re-runs secret
#    restore for newly-cloned siblings, bundles + DBs + Anchor + Playwright,
#    and bounces the Rails servers.
bin/ecosystem-build
```

~25–30 min wall time on a fresh machine. On every later run it's ~30 s — the script just walks ✓ checkmarks and re-bounces the servers, and only one invocation is needed because the siblings are already on disk and have populated `.env` files.

**Where it puts things** (override with `PROJECTS_DIR=...`):
- All 5 repos live under `~/projects/`
- McRitchie Studio at http://localhost:3000
- Turf Monster at http://localhost:3100
- Login: magic link to `alex@mcritchie.studio`

See [`docs/agents/system/house-burn-down.md`](docs/agents/system/house-burn-down.md) for the full protocol, the 12 gotchas it encodes, and the per-phase fallback steps when something breaks.

## Parallel agent worktrees

Use hidden per-task worktrees when an agent should make branch work without touching a primary checkout:

```bash
cd ~/projects/mcritchie-studio
bin/agent-worktree apps
bin/agent-worktree plan turf-monster task-slug
bin/agent-worktree new turf-monster task-slug
bin/agent-worktree up turf-monster task-slug
```

The launcher creates `~/projects/<repo>/.worktrees/<task-slug>`, assigns a port inside the app's reserved range, isolates Redis/session/database settings, and prints the local URL to review.

---

## Single-app dev (when you already have the toolchain)

If your machine already has Ruby 3.1.7, Postgres 14, and an `.env` in place:

```bash
git clone https://github.com/amcritchie/mcritchie-studio.git
cd mcritchie-studio
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server
```

Seeds load 4 agents with avatars, 9 skills, sample tasks, plus 32 NFL + 71 NCAA + 48 FIFA teams, ~2400 active contracts, ~570 PFF-graded athletes, and 47 news articles. Visit http://localhost:3000.

## Prerequisites (single-app path)

- Ruby **3.1.7** (use `brew install ruby@3.1` — not mise/rbenv; see [house-burn-down.md gotcha 1](docs/agents/system/house-burn-down.md))
- PostgreSQL 14+
- Node.js **20+** (Node 18 breaks `turf-vault`'s yarn deps)
- Bundler 2.4+ (`gem install bundler`)

## Test

```bash
# Rails tests
bin/rails test                  # 504 runs, 1322 assertions

# Playwright E2E (chromium only — skip @devnet which needs a funded wallet)
npm test                        # 42 tests
npm run test:headed             # with visible browser
```

## Key Features

- **Dashboard** with agent status, task pipeline (kanban), and activity feed
- **Task management** with enforced state transitions (new, queued, in_progress, done, failed, archived)
- **JSON API** at `/api/v1/` for programmatic task and agent management
- **Expense tracker** with CSV/XLSX parsing and AI categorization (admin-only)
- **Agent docs** viewer at `/docs` with Markdown rendering
- **Dark/light theme** toggle with dynamic color system

## Deploy

```bash
git push heroku main
heroku run bin/rails db:migrate --app mcritchie-studio
```

Platform: Heroku (heroku-24 stack). Required env vars: `RAILS_MASTER_KEY`, `RAILS_SERVE_STATIC_FILES=true`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`.

## Architecture

- Rails 7.2 with ERB views, Tailwind CSS, Alpine.js
- Shared [Studio engine](https://github.com/amcritchie/studio-engine) for auth, error handling, and theme system
- Slug-based foreign keys throughout (not integer IDs)
- All monetary values stored in cents, displayed in dollars

## Development Notes

See [`docs/agents/index.md`](docs/agents/index.md) for agent session context and [`CLAUDE.md`](./CLAUDE.md) only as legacy migration source while the neutral docs are being extracted.
