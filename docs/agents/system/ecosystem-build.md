# bin/ecosystem-build

`mcritchie-studio/bin/ecosystem-build` is the one command that stands up — or
re-verifies — the entire McRitchie dev environment. It is the **fast path**; the
phase-by-phase manual fallback lives in
[house-burn-down.md](house-burn-down.md), which you only drop into when a script
phase fails.

Run it from anywhere; the script locates itself relative to the
`mcritchie-studio` checkout.

```bash
cd ~/projects/mcritchie-studio
bin/ecosystem-build
```

## What it is

A single idempotent Bash script that, phase by phase, **detects current state →
installs/configures only what's missing → verifies**, then bounces the Rails
servers so you finish at a known-good steady state. On a healthy machine it just
walks a column of green checkmarks in well under a minute. There is no separate
"check" mode — re-running *is* the check.

It runs `set -uo pipefail` (no `-e`): each phase reports its own failures and the
script keeps going where it is safe to. When a phase genuinely blocks (e.g. no
1Password token), it prints exactly what to do and exits.

## When to run it

- **Fresh machine** — the full cold-boot rebuild. See the cold-boot note below.
- **Reset to a clean dev state** — after pulling new commits, switching
  branches, or anytime you want to confirm "everything still works." It
  re-migrates, re-checks bundles, and **always** restarts both Rails servers
  (Phase 8) on their registered ports.
- **New satellite app** — add the app to `config/satellites.yml`; the script
  reads it via `load_satellites` and folds the new app into the bundle/DB/server
  phases with no edits to the script itself.

## It is idempotent

Every phase is safe to re-run. Detection precedes action, so already-installed
tools, satisfied bundles, and existing databases are left alone (migrations
still run; seeds only run on first DB creation). Re-running never duplicates
work — it reconciles the machine toward the known-good state and re-bounces the
servers.

`PROJECTS_DIR` overrides the default `~/projects` root
(`PROJECTS_DIR=~/code bin/ecosystem-build`). Opt-in NFL headshots:
`WITH_NFL_HEADSHOTS=1 bin/ecosystem-build` (adds the nflverse CSV + S3 headshot
cache; needs AWS creds in `.env`).

## Cold-boot invocation count

On a truly fresh machine you run it **twice**:

1. **First pass** installs the toolchain (Homebrew packages, Node, Rust, Solana,
   Anchor) and **bails at Phase 4** because the 1Password service token is not
   set yet.
2. Run `bin/setup-1pass-token` (copy your `ops_...` token to the clipboard
   first — see [house-burn-down.md](house-burn-down.md) §5a).
3. **Second pass** picks up at Phase 4 with the token present: writes `.env`
   files, clones the sibling repos, replays the env restore for the freshly
   cloned satellites, then seeds the DBs and boots the servers.

Every later run is a single pass. The token boundary at Phase 4 is the **only**
step that cannot be automated — by design, since the token has to come from your
clipboard.

## Phases

| Phase | Responsibility |
|-------|----------------|
| 1. System tools | Homebrew packages (`ruby@3.3`, `postgresql@14`, `redis`, `mise`, `gh`, `heroku`, `jq`, etc.), starts Postgres + Redis services, verifies the Ruby socket extension |
| 2. Languages | Node 22 + yarn (mise), Rust 1.89.0 (rustup), Solana CLI (Anza), Anchor 0.32.1 (cargo), local Solana devnet keypair |
| 3. Shell config | `~/.zshrc` PATH lines (brew Ruby, mise, Solana, Cargo), `~/.zprofile` chmod 600 |
| 4. Secrets | Verifies `OP_SERVICE_ACCOUNT_TOKEN`; pulls Heroku key from 1Password; restores each active Rails app's `.env`. **Bails here on the first pass if the OP token is missing.** |
| 5. Sibling repos | `gh repo clone` for `studio-engine`, `solana-studio`, `turf-vault`, and any satellites (skips ones already present) |
| 5b. Agent docs | Runs `bin/install-agent-docs`, which installs **both** entrypoints to `$PROJECTS_DIR`: `AGENTS.md` (from `docs/agents/index.md`, read natively by Codex) and `CLAUDE.md` (from `docs/agents/claude.md`, the Claude Code adapter that `@import`s AGENTS.md). Claude Code auto-loads `CLAUDE.md` but not `AGENTS.md`, so both are required. |
| 5c. Secrets replay | Re-runs Phase 4 now that sibling repos exist, so newly cloned satellites get their `.env` before DB setup |
| 6. Bundles + DBs | `bundle install` (only when `bundle check` fails) + `db:migrate` (existing DB) or `db:create db:migrate db:seed` (first run) for each Rails app; bundle for `solana-studio` |
| 6b. NFL data | Always runs: live schedule + ESPN depth-chart scrape + current-week roster snapshot + preseason rankings (~3-5 min, network only) |
| 6c. NFL headshots | Opt-in via `WITH_NFL_HEADSHOTS=1`: nflverse master CSV + S3 headshot cache (~10-15 min, needs AWS creds) |
| 7. Anchor + e2e | `yarn install` + `anchor build` for `turf-vault`; `npm install` + `npx playwright install chromium` for the Rails apps |
| 8. Servers | **Always** kills + restarts each active Rails app on its registered port, then curls each to verify HTTP 2xx/3xx |
| 9. Env snapshot | Writes `mcritchie-studio/tmp/env-snapshot-YYYY-MM-DD.json` (raw `.env` contents, gitignored, chmod 600) as a Heroku-independent secret-recovery fallback |

## Reset semantics

"Reset" here means **re-converge to a clean running state**, not "wipe and
rebuild from scratch":

- **Servers are always reset** — Phase 8 kills whatever is on each registered
  port (by pidfile and by `lsof`), then starts a fresh detached `rails server`
  and verifies it responds. This is why a plain re-run is the canonical "get me
  back to a clean dev state" action.
- **Databases are preserved** — an existing development DB is migrated, not
  dropped; seeds only run when the DB is first created. The script never
  destroys data. For a true data reset, run `bin/rails db:reset` in the app
  yourself, then re-run `bin/ecosystem-build` to re-seed and re-boot.
- **Tools and bundles are reconciled, not reinstalled** — already-present tools
  and satisfied bundles are left untouched.

## Seeding QA/prod environments

`bin/ecosystem-build` runs the full `rails db:seed` only on **first local DB
creation** (Phase 6). **Do not run the full seed on a hosted environment** — it
loads demo data (`52_tasks.rb`, `53_activities.rb`) plus the sports fixtures,
which would pollute a QA/prod board.

For QA/prod (Heroku), seed only the **idempotent reference registries** (find-or-
create upserts — no duplicates, no demo rows), safe to re-run on any deploy:

- **Agent registry** — souls + avatars + review roles. This is what populates the
  **agent images** on the board crew (a fresh environment shows initials until it
  runs):

  ```bash
  heroku run -a <app> rails runner 'load Rails.root.join("db/seeds/02_agents.rb").to_s'
  ```

- **Pokémon mascot deck** — the per-session task mascots:

  ```bash
  heroku run -a <app> rake pokemon:seed
  ```

Re-run the agent registry on any deploy that changes a soul's metadata, avatar,
or review weight.

## Cross-references

- [house-burn-down.md](house-burn-down.md) — the detailed phase-by-phase manual
  fallback, gotchas (Appendix A), and tooling-version reference (Appendix C)
- `bin/install-agent-docs` — installs the `AGENTS.md` + `CLAUDE.md` entrypoints
- `bin/setup-1pass-token` — the Phase 4 token boundary
- `config/satellites.yml` — the satellite registry the script reads
</content>
</invoke>
