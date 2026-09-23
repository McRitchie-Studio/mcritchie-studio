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
| 4. Secrets | Verifies `OP_SERVICE_ACCOUNT_TOKEN` **and that the agent vault is visible to it** (see [The Phase 4 vault guard](#the-phase-4-vault-guard)); pulls Heroku key from 1Password; restores each active Rails app's `.env`. **Bails here on the first pass if the OP token is missing.** |
| 5. Sibling repos | `gh repo clone` for `studio-engine`, `solana-studio`, `turf-vault`, and any satellites (skips ones already present) |
| 5b. Agent runtime | Runs `bin/agent-runtime install`, which installs **both** entrypoints to `$PROJECTS_DIR`: `AGENTS.md` (from `docs/agents/index.md`, read natively by Codex) and `CLAUDE.md` (from `docs/agents/claude.md`, the Claude Code adapter that `@import`s AGENTS.md). It mirrors the shared user-global agent skills `docs/agents/skills/*` → `~/.claude/skills/*` + `~/.codex/skills/*`, configures Codex marker hooks, and keeps `bin/install-agent-docs` as the lower-level copy/drift implementation. |
| 5c. Secrets replay | Re-runs Phase 4 now that sibling repos exist, so newly cloned satellites get their `.env` before DB setup |
| 6. Bundles + DBs | `bundle install` (only when `bundle check` fails) + `db:migrate` (existing DB) or `db:create db:migrate db:seed` (first run) for each Rails app; bundle for `solana-studio` |
| 6b. NFL data | Always runs: live schedule + ESPN depth-chart scrape + current-week roster snapshot + preseason rankings (~3-5 min, network only). Every task here can now report its own failure — see [How 6b and 6c decide they failed](#how-6b-and-6c-decide-they-failed) |
| 6c. NFL headshots | Opt-in via `WITH_NFL_HEADSHOTS=1`: nflverse master CSV + S3 headshot cache (~10-15 min, needs AWS creds). A credential failure is reported, not logged green — see [How 6b and 6c decide they failed](#how-6b-and-6c-decide-they-failed) |
| 7. Anchor + e2e | `yarn install` + `anchor build` for `turf-vault`; `npm install` + `npx playwright install chromium` for the Rails apps |
| 8. Servers | **Always** kills + restarts each active Rails app on its registered port, then curls each to verify HTTP 2xx/3xx |
| 9. Env snapshot | Writes `mcritchie-studio/tmp/env-snapshot-YYYY-MM-DD.json` (raw `.env` contents, gitignored, chmod 600) as a Heroku-independent secret-recovery fallback |

## How 6b and 6c decide they failed

**The short version: a lane is graded on a signal that CHANGES when the import
breaks.** That reads like a tautology and is not — four of these lanes were
graded on signals that could not change, at the same time, and each one logged a
green line through a total outage.

Every importer in these two phases rescues a per-item failure ON PURPOSE. One
unreachable ESPN team must not cost the other 31 their refresh; one dead
headshot URL must not cost the other thousand theirs; a dead nflverse feed must
not abort a deploy, because the app is fine and only the data is stale. Those
rescues are right. The cost is that the process exits 0 however much failed, and
for a while nothing above them turned "all of it failed" into a verdict.

Measured 2026-09-23, each in a desk against the real code:

| Lane | What a total failure used to look like | What it looks like now |
|------|----------------------------------------|------------------------|
| `espn:scrape_depth_charts` | `{:teams_failed=>32}` printed, exit 0, green entry count logged | refuses a run that applied NO teams; a partial run stays green and reports its per-bucket tally on stderr |
| `nfl:upload_headshots` | every candidate raised `Aws::Errors::MissingCredentialsError`, `failed: 3 cached: 0`, exit 0 | refuses a run where more uploads failed than succeeded, and names the AWS variables to check |
| `nfl:rankings_compute` | wrote the SAME 448 rows a healthy run writes, every score `0.0`, exit 0 | refuses a ranking where every team scored zero, and names `GRADES_FROM` |
| `nfl:players_seed` | exit 0 through a rescued feed outage | graded on the exit code AND an `ImportRun` success pinned to THIS run's start |

`nfl:schedule_seed` was measured too and left alone: it raises on an empty
feed, so its exit code discriminates a dead feed.

`nfl:rosters_snapshot` was measured and left alone for a NARROWER reason, and
reading the two as one sentence is how a sixth lane gets certified by accident.
It aborts on its own PRECONDITIONS — a missing season or slate — and then ends
on `puts` over a tally `Rosters::SnapshotFromDepthChart` returns without ever
raising, so a ZERO-WORK snapshot still exits 0. That is a fifth instance of the
pattern above and this pass does NOT fix it. It is reachable as the direct
downstream of the failure phase 6b logs one line earlier: `Espn::ScrapeDepthCharts`
creates each `DepthChart` row BEFORE it fetches, so a total ESPN outage leaves 32
EMPTY charts, the snapshot reports 32 teams and 0 spots, and the lane logs a green
team-roster count underneath the ✗ it just printed. Known open, not measured clean.

Three rules the next lane added here should copy.

- **The verdict lives in the rake task, never in the service.** `lib/tasks/espn.rake`
  grades the tally `Espn::ScrapeDepthCharts` already returns, rather than making
  the service raise. The service has other callers that need its tolerance; only
  the LANE needs an exit code. Same for `nfl:upload_headshots` and
  `nfl:rankings_compute` in `lib/tasks/nfl.rake`.
- **AND two signals; never swap one for the other.** Phase 6c grades
  `nfl:players_seed` on the exit code AND the `ImportRun` row, because each
  catches what the other cannot: the row sees a rescued outage the exit code
  cannot, and the exit code sees a crash the row cannot. A PR that replaced the
  exit code with the row traded one false green for another. Before replacing
  signal A with signal B, write out every cell where they disagree — in BOTH
  directions.
- **A count is a LEVEL, not a delta.** "4321 entries with ESPN formation_slot",
  "448 rank rows populated" and "1100 cached variants" all survive an outage
  untouched, because they count what is in the database, not what this run put
  there. None of them can be a verdict. Where a count is genuinely all there is,
  pin it to the run — which is what `ImportRun.fresh_success?(since:)` does, and
  why an unreadable boundary is refused rather than quietly widened.

The phase wiring is driven end-to-end by
`test/lib/ecosystem_build_nfl_data_verdict_test.rb` and
`test/lib/ecosystem_build_import_verdict_test.rb`, which source the script and
stub `bundle`; the tasks’ own verdicts are driven against the database by
`test/lib/tasks/rebuild_lane_verdict_test.rb`. Both halves are needed, and
either one alone reads as fixed.

## The Phase 4 vault guard

Phase 4 asks one question before it spends a credential: **is the agent vault
visible to this token?** The answer gates the whole rest of the run, so the
guard is a named function — `agent_vault_visible` at the top of
`bin/ecosystem-build` — rather than an inline pipeline, and
`test/lib/ecosystem_build_vault_guard_test.rb` drives it against a synthetic
`op`.

Three rules, and each one is there because its absence cost something:

- **The vault name comes from `MCR_OP_VAULT_AGENT`, defaulting to
  `studio-agents`** — mirroring `bin/lib/op_vaults.rb`, which is the single
  source. Only the guard binds that default to a variable; Phase 4's other vault
  reads expand it inline, and some of its hints name it outright. So a new
  default has to be set at every non-comment `studio-agents` in `phase_secrets`
  (skipping `studio-agents-admin`), not only at the guard. Neither this page nor
  the script gives a site count, deliberately: the count went from three to two
  to four between 2026-08-30 and 2026-09-15, as `SOLANA_ADMIN_KEY` left the
  agent vault and came back, and each stated number outlived its truth.
- **The name is matched EXACTLY.** The guard read `op vault list | grep -qw
  agents` until 2026-08-29 and passed against `studio-agents`, because `-w`
  treats a hyphen as a word boundary — so it reported the credential lane
  healthy for as long as the vault it guarded had been gone. The 1Password
  account holds four vaults whose names begin `agents` (`studio-agents`, `studio-agents-admin`,
  `industries-agents`, `family-agents`), so "contains the word
  agents" was never the question.
- **It fails closed.** Absent, empty, unparseable, or non-array output from `op`
  is not evidence a vault is reachable, so every one of them is a refusal.

Its three outcomes get three different messages, because two of them send the
reader to different places:

| Outcome | What it means | Where to look |
|---------|---------------|---------------|
| `✓ ... agent vault '<name>' visible` | matched by exact name in `op vault list` | — |
| `✗ OP token set but can't see the '<name>' agent vault` | op answered without naming the vault, or op itself failed | the token's vault grants, or set `MCR_OP_VAULT_AGENT` — but rule out an expired token and a dead network first |
| `✗ can't check the '<name>' agent vault — op and jq are not both installed` | the listing could never be read | Phase 1, which installs both |

The last row is a separate message on purpose. Sending an operator to audit
1Password grants when the real fault is an uninstalled binary is a confident,
specific, wrong diagnosis, and the remedy it prescribes is pure waste.

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
- `bin/agent-runtime` — installs and checks the `AGENTS.md` + `CLAUDE.md`
  entrypoints, shared user-global agent skills (`docs/agents/skills/*` →
  `~/.claude/skills/*` + `~/.codex/skills/*`), and Codex marker hooks
- `bin/setup-1pass-token` — the Phase 4 token boundary (AGENT lane).
  `bin/setup-1pass-token --admin` installs the SHIP lane's token into
  `~/.zprofile.admin`, which is not auto-loaded — see
  `docs/agents/modules/credentials.md` for the two-vault map. Phase 4
  verifies only the AGENT token; a missing ADMIN token stays silent until
  a production deploy, so verify it explicitly with
  `bin/gh-token --identity deployer`.
- `config/satellites.yml` — the satellite registry the script reads
