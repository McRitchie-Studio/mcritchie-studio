# Worktrees

Every code or active-doc edit happens in an isolated worktree (a **desk**,
`/Users/alex/projects/<repo>/.worktrees/<task-slug>`) on an allocated port; primary
checkouts are loading docks. History cut from this page:
[`../archive/worktrees-2026-09-25.md`](../archive/worktrees-2026-09-25.md).

## Fresh Worktree Checklist

**Steps 1-3 are what `bin/task begin` automates** (`bin/task begin --title "Three To Five Words" --repo <app> --agent <soul> …`;
resume with `bin/task begin <task-slug>`). Steps 4-9 apply either way.

1. **Create the desk** — `bin/agent-worktree new <app> <task-slug>` cuts `feat/<task-slug>`
   from the base ref (`accepted`, else `release`, else `main`), writes `.env.agent-stack`,
   provisions the isolated test DB, and builds `app/assets/builds/tailwind.css`.
2. **Bind the task immediately** — `bin/agent-worktree bind-task <app> <task-slug>
   <task-record-slug-or-url>`; `new` does NOT auto-bind.
3. **Preflight the desk** — `bin/session-preflight <task-slug> --root <desk>` (the hub's
   copy). Resolve what touches YOUR task before editing.
4. **Verify env and port** — `bin/agent-worktree whereami`; no port means re-run `new`.
5. **Verify assets and test DB** — `app/assets/builds/tailwind.css` exists; else run
   `RAILS_ENV=test bin/rails db:test:prepare test:prepare` (the env var is load-bearing).
6. **Boot, then prove the URL** — `bin/agent-worktree up <app> <task-slug>` runs
   `db:prepare` and polls `/up`; hand out a URL only after it returns 200.
7. **Know your data** — the stack DB starts from schema + seeds; seed what the demo needs.
8. **Run tests through the wrapper** — `bin/agent-worktree test <app> <task-slug>` in
   EVERY repo (hermetic, isolated test DB, `PARALLEL_WORKERS=1`). A plain `bin/rails test`
   is fine only in the hub. Do not source `.env.agent-stack` before tests.
9. **Email lands locally** — at `http://localhost:<port>/_studio/local_emails`.

## Startup Rule

Without the fast lane: agree acceptance criteria; create the production task; `bin/agent-worktree
plan <app> <task-slug>`; `new`; `bind-task`; move the task to `building`; `up` when a URL is
needed; edit only inside the desk. When the local behavior is ready for Alex:

```bash
bin/task update <task-slug> --local-url http://localhost:<port>/<path> --approval waiting
```

```text
Task: https://mcritchie.studio/tasks/<task-slug>
Local Demo: http://localhost:<port>/<path>
Local Inbox: http://localhost:<port>/_studio/local_emails   # only for email/auth flows
```

The request survives `bin/ship`; the window closes at `reviewed`. **The desk is NOT yet
reclaimable there** — `RECLAIMABLE_STAGES` is `%w[shipped archived]`. Then commit, `finish`,
record the PR and `checks_run`, and move to `submitted`. Exceptions: read-only audits, the
deploy owner, and emergencies (say why).

## Launcher

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-worktree plan|new|up|status|down|finish <app> <task-slug>
bin/agent-worktree bind-task <app> <task-slug> task-abc123def456
bin/agent-worktree list | whereami | doctor | snapshot --write | scale status
bin/agent-worktree cleanup [--write | --reclaim [--yes]]
bin/agent-worktree remove <app> <task-slug> --yes
bin/agent-worktree sweep-orphan-dbs          # dry run; --yes drops orphaned desk DBs
```

### A desk commits as its claiming soul

`new --soul <soul>` (passed by `bin/task begin --agent <soul>`) stamps the desk's **own**
`config.worktree` with the soul's identity; re-stamp with `bin/agent-worktree identity <app>
<slug> <soul>`. It never writes `~/.gitconfig` and refuses a primary. Without `--soul`, `new`
prints `identity: UNSTAMPED`. **A desk cut by hand gets no stamp and no warning**
(studio-engine, solana-studio, turf-vault): cut it at `<repo>/.worktrees/<slug>` and run
`/Users/alex/projects/mcritchie-studio/bin/agent-worktree identity <repo> <slug> <soul>`.

**Never run a plain `git config user.name` in a desk**: without `--worktree` it renames
every desk in the repo ([source-control.md → Commit Authorship](source-control.md#commit-authorship--which-soul-git-log-names)).

### Every subcommand accounts for its whole command line

`--help` anywhere answers and does nothing; an unknown argument is refused. Help exits
**1**, a refusal **2**, a leaky teardown **3**; exit 0 is a fact callers rely on.
`test … -- <args>` forwards its tail to `bin/rails test` (`AgentWorktreeCli::COMMANDS`).

### `new` is atomic: a complete desk, or nothing

Every step registers its inverse and any exit (SIGINT, SIGTERM, SIGHUP) unwinds them; an
unfinished rollback prints `unwind INCOMPLETE for <label>`. Bringup is idempotent, so the
repair for any partial desk is to re-run `bin/agent-worktree new <app> <task-slug>`.

**When the band is full**, `new` refuses before cutting anything. Remedies, cheapest first:

```bash
bin/agent-worktree cleanup --reclaim         # dry run: merged + clean desks, safe to release
bin/agent-worktree cleanup --reclaim --yes   # release them, shrinking the band
bin/agent-worktree scale --provision         # INFRA LANE: raises the Redis ceiling, restarts Redis,
                                             # bounces every running stack
```

The reclaim withholds any desk bound to a task the board does not yet show as
`shipped` or `archived`, so a band full of merged-but-unshipped desks reclaims
nothing. Free one of those by hand, once you know its work is safe on `accepted`:
`bin/agent-worktree remove <app> <task-slug> --yes`.

## Lifecycle

- `list` shows health, URL, branch, dirty/merge state, database, Redis DB and pidfile.
- `finish` blocks dirty, empty, stale or already-merged branches. `--push --pr` opens a draft
  PR on the base branch and stamps `devops.pr_url` on the bound task.
- `doctor` reports drift and **orphan** worktrees (prune a stale one with `git -C <repo> worktree prune`).
- `snapshot --write` writes the non-secret cross-app registry to
  `/Users/alex/projects/.agents/worktree-registry.json` (override `AGENT_WORKTREE_REGISTRY`).
- `cleanup` is a dry run: clean candidates merged into, or diff-equivalent to, the base ref,
  each with its safety class, `rationale:` line, and exact `remove … --yes` command. That
  dry run is the approval packet.
- `cleanup --write` files candidates on the **desk ledger** (`DeskRecord`, Desks panel on
  [/deployments](https://mcritchie.studio/deployments)). A teardown files its record
  **before** destroying anything, so **when the board is unreachable the teardown
  REFUSES**. [`../maintenance/delete-later.md`](../maintenance/delete-later.md) is history.

### The reclaim safety rule

A fresh desk and a merged one are **git-identical**, so git alone never frees a desk.
**Six independent channels** decide, through ONE decision every path shares
(`reclaim_verdict`), as an `||` chain, in order:

1. **ORIGIN** (`origin_hold`) — a gone or unreachable remote withholds.
2. **CLAIM** (`claim_hold`) — an old lease row, if any; `_ship`/`_gate` are held by ANY live
   `ReleaseConductorClaim` (`assembler` + `deployer`). An unbound desk on a **discovered
   repo** (studio-engine) gets a hold outright — a **short-circuit**: the later channels
   never run at all. **No discovered desk is ever auto-reclaimed**; use `remove`.
3. **STAGE** (`stage_hold`) — frees a bound desk only at `shipped` or `archived`, failing
   closed on an unreadable board (withholding defers; freeing is irreversible).
4. **REVIEW** (`review_hold`) — a reviewer on the task (`review_in_progress`) holds it.
5. **DESK** (`desk_hold`) — desk age under `ClaimLease::DESK_IDLE_SECONDS` (1h29m), recent
   mtimes (`DeskActivity.touched_since?`), or the holder's gate in flight. Every unknown holds.
6. **PR** (`pr_hold`) — an open, unmerged PR holds; with `gh` unreachable the board's
   `pr_url` without a `merged` stamp holds.

So a desk is `reclaimable?` only when clean, merged, and cleared by all six — its task at
`shipped` or `archived` included. `quiet` never frees a desk, and no lane fails open. **The
cost:** a bound desk stands through the whole release cycle.

- `cleanup --reclaim --yes` tears each candidate down like `remove`, re-verifying under the
  lock, then shrinks the Redis band. Safe to re-run.
- `remove <app> <task-slug> --yes` is the operator override (warns on a live claim, refuses
  a dirty desk): record first, then stack, Redis DB, Postgres DBs, worktree and branch.
- **A spared process is a leak**: `teardown-leak: …`, a **`leaked`** record, exit **3**.
  Check `ps -o pid,command -p <pid>`; stop it by hand only if it is the desk's.

Deletion stays approval-gated: `cleanup <app>`, confirm `doctor <app>` shows no unique
work, `remove <app> <task-slug> --yes` after approval, then `bin/qa-intake --refresh --apps
<apps>`. For a squash-merged branch, confirm `git diff --stat origin/accepted..HEAD` and
`git diff --name-status origin/accepted..HEAD` are empty first; if not, do not delete.

## Rules

- Branch from the **base ref** (`accepted`, else `release`, else `main`); PRs target it.
- One task branch per worktree. Never commit task work on a primary unless you are the
  deploy owner. A pushed feature branch is the backup, not `main`.
- A dirty or moving primary is shared-floor drift: report it, do not fold it in.
- Do not remove a worktree until its branch/PR status is known; log it on the desk ledger.
- **One writer per desk — the build-claim holder.** See
  [The Desk Writer Convention](#the-desk-writer-convention).

## The Desk Writer Convention

### One writer per desk: the build-claim holder

**The desk belongs to whoever holds the task's build claim, and the build claim is the
desk bound to the task** (`bin/lib/desk_claim.rb`). Conductor, primary reviewer, and light
reviewer read. Reading (`git log`, `git diff`, opening files) is unrestricted; a mutation,
`git stash`, a path checkout, an editor save or a `bin/rails db:*` is a write. **A task
claim is not a desk claim**: a review claim never licenses writes.

### How to tell whether someone is already in a desk

```bash
bin/task show <slug> --verbose             # `claim: desk <path> · <GRADE> · session …`
bin/task review-claim status <slug>        # OBSERVES the review lease: renewing, dying, or free
bin/agent-worktree list | grep -A1 <slug>  # the desk's `dirty` flag and live pid

# Has anyone touched the files in the last 10 minutes? (mtime walk, .git and tmp pruned)
ruby -I lib -r desk_activity \
  -e 'puts DeskActivity.touched_since?(ARGV[0], Time.now - 600).inspect' \
  "$PWD/.worktrees/<slug>"
```

`move … building`, `begin` and `bin/ship` **refuse** only when another live session's bound
desk has uncommitted changes; `--steal` overrides. **A REVIEWER is asked, never stolen from**
(`bin/task review-claim release <slug>`, run by them).

### If you believe a builder lost work, tell the builder

Report it on the task record and let the writer decide; **do not reconstruct the work
yourself**. If the builder is gone, become the writer first:

```bash
bin/task move <slug> building --actor <soul>   # claims when no other live desk is dirty
bin/task begin <slug> --steal --agent <soul>   # takes over a LIVE holder, deliberately
```

### Mutation testing never runs in a shared desk

**Run every mutation pass on a throwaway desk** (the [zap protocol's](zap-protocol.md) rule):

```bash
REPO="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"   # the PRIMARY checkout, from anywhere
MUT="$REPO/.worktrees/mut-<slug>"
git worktree add "$MUT" --detach <pr-head>
cp <desk>/.env.test.local "$MUT"/                        # REQUIRED — see below
(cd "$MUT" && bin/rails test:prepare)                    # REQUIRED — see below
```

- **`.env.test.local` is untracked**; without it the throwaway runs on the SHARED test DB.
- **Put it under `.worktrees/`**, so `bin/lib/desk_guard.rb` recognizes it as a desk.
- **`bin/rails test:prepare` builds the gitignored assets**; without it a mutant reads as
  caught when the tree only lacks `tailwind.css`.

One mutator on an idle desk: the throwaway above. Two mutators, or a busy desk: a real desk
each (`bin/agent-worktree new <app> <slug>`), since copies of one `.env.test.local` share a DB.

### A sanctioned non-writer commit announces itself first

A reviewer zap: `bin/task note` on the task **before** pushing, a subject prefixed `zap:`,
and CI re-runs on the new head (a `test-only` `[control@<fp>]` stamp is retaken).

### What already enforces this, and what does not

| Check | Where | Catches |
|---|---|---|
| Control stamp fingerprint (`test-only` PRs) | `bin/dor-check <task>` grades `[control@<fp>]` against the tree | Any foreign change to the desk's working tree after the control ran |
| Shared-test-DB refusal | `bin/lib/desk_guard.rb`, the pre-flight | A desk **or throwaway under `.worktrees/`** on the shared test DB |
| Desk occupancy | `DeskActivity.touched_since?`, `bin/agent-worktree list` | Someone working in a desk right now |
| Reclaim withhold | `desk_hold` + `stage_hold`, `bin/agent-worktree cleanup --reclaim` | Destroying a desk younger than 1h29m, touched, mid-gate, or bound to a task the board does not put at `shipped`/`archived` |

Git authorship names the CLAIMING soul, so it cannot expose a foreign write.

### The session scratchpad is shared — namespace every write

**Namespace every write with the task slug** (`ship-<task-slug>.log`, not `ship.log`;
`scratchpad/<task-slug>/…`); `>>` interleaves. A collided log reads `data` to `file`. For a
copy you mean to restore, use `bin/scratch-backup`:

```bash
bin/scratch-backup save    bin/agent-worktree   # before you mutate it
bin/scratch-backup restore bin/agent-worktree   # refuses if it is not your copy
bin/scratch-backup verify  bin/agent-worktree   # exit 0 = intact, 3 = not
bin/scratch-backup list                         # your namespace, with statuses
```

## Multi-Agent Safety & Merge Patterns

Agents converging on one branch each get `git worktree add -b <branch> .worktrees/<slug>
<base>`; prefer new files and one `<%= render %>` line per shared view; one migration owner;
keep both blocks at a CSS end-of-file conflict; merge sequentially, suite green between.

## Handoff Contract

Task URL first; then branch, desk path, local URLs, PR URL, `checks_run` and readiness.
Never leave Alex with "run these commands."

## Terminal Context

Every desk carries a git-excluded `.agent-context.json`; `whereami --shell` exports
`AGENT_CONTEXT_*` from its scalar fields (never trust shell lines stored in it). Evergreen
title: `eval "$(/Users/alex/projects/mcritchie-studio/bin/agent-worktree shell-hook zsh)"`.

## Worktree Stack Requirements

Each stack gets its own port ([`ports-and-processes.md`](ports-and-processes.md)), Redis DB,
dev and test databases, cookie key, `APP_PORT`, and `LOCAL_EMAIL_CAPTURE=1` (set `0` only to
test real delivery). Never let two Sidekiq processes share a Redis DB. Callback-heavy flows
(Stripe, OAuth, webhooks) stay on the primary port unless configured for the desk's.

Every write of `.env.agent-stack` (`new`, `bind-task`) also writes `.env.development.local`
with the desk's `DATABASE_URL`, `REDIS_URL` and `PORT`. dotenv loads it for the development
env, so a bare `bin/rails db:prepare` or `bin/rails runner` in a hub desk reaches the desk's
own database whether or not the stack was ever booted. A hub desk WITHOUT that pointer is
refused by `config/initializers/desk_database_guard.rb` rather than handed the shared
`mcritchie_studio_development`; the refusal prints the fix, `bin/agent-worktree new
mcritchie-studio <slug>`. `ALLOW_SHARED_DEV_DB=1` overrides it when you mean the shared DB.

## Running tests

`new` writes `.env.test.local` with `TEST_DATABASE_URL`, so `bin/rails test` in a hub desk
resolves to the isolated DB; `bin/agent-worktree test <app> <slug>` is the hermetic path. Do
**not** `source .env.agent-stack` before tests (it routes mail into local capture).

### The desk guard

`bin/fast-check` **refuses a desk whose test database is the repo's shared one**
(`bin/lib/desk_guard.rb`, which boots the app and reads the database it really uses). It is
an env/config issue: re-provision with `bin/agent-worktree new <app> <slug>`, or make the
repo's `config/database.yml` read `TEST_DATABASE_URL`.

## Scale Note

Physical capacity is Redis `databases` (fixed at startup; stock is 16). The **soft band**
starts at DB `9`, idles at **20 slots** (`FLOOR`) and moves by **10** (`STEP`):

- **Scale-out (auto):** a full band grows by 10 with no restart; at the physical ceiling it
  aborts with guidance to run `cleanup` or `scale --provision`.
- **Scale-in (auto):** `remove`, `cleanup --write` and `cleanup --reclaim --yes` shrink it by
  10, never below the floor or past a used DB.
- `scale status` prints the band and ceiling; `scale out` / `scale in` nudge it by hand.

The full floor needs `databases >= 29`. To raise it (one-time, target 64):

```bash
bin/agent-worktree scale --provision         # interactive confirm
bin/agent-worktree scale --provision --yes   # skip the prompt
```

It restarts Redis once, **bouncing every running stack**: QA/infra lane, quiet window only.
