# McRitchie Studio

Task management and orchestration hub for the McRitchie AI agent system. McRitchie Studio is also the documentation anchor for the full local development stack: if the machine is wiped, this repo is the first clone and the source of truth for rebuilding the ecosystem.

**Live**: https://mcritchie.studio

Legacy Rails host: https://app.mcritchie.studio. Previous Squarespace site:
https://v1.mcritchie.studio.

McRitchie Studio is the **flagship app** of the McRitchie ecosystem ([turf-monster](https://github.com/McRitchie-Studio/turf-monster), [chain-ops](https://github.com/McRitchie-Studio/chain-ops), [studio-engine](https://github.com/McRitchie-Studio/studio-engine), [solana-studio](https://github.com/McRitchie-Studio/solana-studio), [turf-vault](https://github.com/McRitchie-Studio/turf-vault), and future apps). Clone this repo first; it carries the scripts and agent-neutral docs that bootstrap everything else.

> **New here?** Read [`docs/ECOSYSTEM.md`](docs/ECOSYSTEM.md) first — it's the canonical 2-minute orientation surface for the ecosystem.

> **Agent session?** Run `bin/agent-runtime install` after cloning or pulling this repo. It refreshes `/Users/alex/projects/AGENTS.md` from the tracked source at [`docs/agents/index.md`](docs/agents/index.md), installs shared agent skills and Codex hooks, then prints the next context files to read. Use `bin/agent-runtime doctor` to inspect drift and runtime hook state.

---

## Fresh-Mac ecosystem recovery (the canonical path)

Use this when standing up a brand new machine, or anytime you want to confirm "everything still works." Idempotent — safe to re-run.

**One-time prereqs** (NOT auto-installed):
- macOS with Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh)
- A 1Password service account token with **read** access to the `studio-agents` vault — the agent vault (account `alex@mcritchie.studio`). Generate at https://start.1password.com → Developer Tools → Service Accounts. Ship lanes need a SEPARATE token with read on `studio-agents-admin`, installed with `bin/setup-1pass-token --admin`.

```bash
# 1. Clone the flagship — every other repo + script lives downstream of this one.
git clone https://github.com/McRitchie-Studio/mcritchie-studio.git ~/projects/mcritchie-studio
cd ~/projects/mcritchie-studio

# 2. First pass — installs every brew package (incl. 1Password CLI), Rust, Solana,
#    Anchor, etc. Bails at Phase 4 once it needs your 1Password service token.
bin/ecosystem-build

# 3. Copy your 1Password service account token (ops_...) to clipboard, then:
bin/setup-1pass-token

# 4. Second pass — picks up at Phase 4, pulls Heroku key + .env, clones the
#    sibling repos, installs the projects-level AGENTS.md, re-runs secret
#    restore for newly-cloned siblings, bundles + DBs + Anchor + Playwright,
#    and bounces the Rails servers.
bin/ecosystem-build
```

~25–30 min wall time on a fresh machine. On every later run it's ~30 s — the script just walks ✓ checkmarks and re-bounces the servers, and only one invocation is needed because the siblings are already on disk and have populated `.env` files.

**Where it puts things** (override with `PROJECTS_DIR=...`):
- The ecosystem repos live under `~/projects/`
- McRitchie Studio at http://localhost:3000
- Turf Monster at http://localhost:3100
- Login: magic link to `alex@mcritchie.studio`

See [`docs/agents/system/house-burn-down.md`](docs/agents/system/house-burn-down.md) for the full protocol, the 12 gotchas it encodes, and the per-phase fallback steps when something breaks.

## Parallel agent worktrees

Use hidden per-task worktrees when an agent should make branch work without touching a primary checkout. For code or active-doc edits, this is the default path:

```bash
cd ~/projects/mcritchie-studio
bin/agent-worktree apps
bin/agent-worktree plan turf-monster task-slug
bin/agent-worktree new turf-monster task-slug
bin/agent-worktree up turf-monster task-slug
```

The launcher creates `~/projects/<repo>/.worktrees/<task-slug>`, assigns a port inside the app's reserved range, isolates Redis/session/database settings, and prints the local URL to review.

Primary checkouts are integration/deploy lanes. Feature agents should not commit
from them unless they are explicitly acting as the deploy owner.

For QA / Integration lane sessions, build Avi's intake queue from the local
worktree registry and open PRs:

```bash
cd ~/projects/mcritchie-studio
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster
```

This labels open work as ready for Avi, needing checks review, needing the
feature agent, missing a local branch, ready to open a PR, or safe to ledger for
later cleanup. Each queue item prints an `action:` line; follow that before
guessing at the next owner.

## Adding or promoting apps

The managed satellite registry is `config/satellites.yml`. Before adding an app
to shared automation, validate its range and metadata:

```bash
cd ~/projects/mcritchie-studio
bin/register-satellite --list
bin/register-satellite --slug next-app --port 3500 --description "One-line product summary" --dry-run
```

Tax Studio is planned at `3200-3299`, Rolio is reserved at `3300-3399`, and
Chain Ops is planned at `3400-3499`. See
[`docs/agents/modules/app-registry.md`](docs/agents/modules/app-registry.md).

---

## Single-app dev (when you already have the toolchain)

If your machine already has Ruby 3.3.11, Postgres 14, and an `.env` in place:

```bash
git clone https://github.com/McRitchie-Studio/mcritchie-studio.git
cd mcritchie-studio
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server
```

Seeds load 9 agents with avatars, 35 skills, sample tasks, plus 32 NFL + 75 NCAA + 48 FIFA teams, 38 NFL schedule arenas, active contracts, PFF-graded athletes, and news articles. Visit http://localhost:3000.

## Prerequisites (single-app path)

- Ruby **3.3.11** (use Homebrew Ruby and match `.ruby-version`; see [house-burn-down.md gotcha 1](docs/agents/system/house-burn-down.md))
- PostgreSQL 14+
- Node.js **22.x** (keeps local dev, CI, and Heroku aligned; `turf-vault` needs at least Node 20.18.0)
- Bundler 2.4+ (`gem install bundler`)

## Test

```bash
# Rails tests
bin/rails test

# Playwright E2E (chromium only — skip @devnet which needs a funded wallet)
npm test
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
heroku ps:scale worker=1 --app mcritchie-studio
```

Platform: Heroku (heroku-26 stack). The `release` process runs
`bin/rails db:migrate` before each deploy is promoted. Keep one `worker` dyno
scaled so Solid Queue can process durable mail/auth jobs. Required env vars:
`RAILS_MASTER_KEY`, `RAILS_SERVE_STATIC_FILES=true`, `GOOGLE_CLIENT_ID`,
`GOOGLE_CLIENT_SECRET`.

## Architecture

- Rails 8.1 with ERB views, Tailwind CSS, Alpine.js
- Shared [Studio engine](https://github.com/McRitchie-Studio/studio-engine) for auth, error handling, and theme system
- Slug-based foreign keys throughout (not integer IDs)
- All monetary values stored in cents, displayed in dollars

## Development Notes

See [`docs/agents/index.md`](docs/agents/index.md) for agent session context. Legacy LLM-specific files are migration sources only; track their removal in [`docs/agents/maintenance/delete-later.md`](docs/agents/maintenance/delete-later.md).
