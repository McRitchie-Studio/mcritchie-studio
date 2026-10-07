# Worktrees

Every code or active-doc edit happens in an isolated worktree (a **desk**,
`/Users/alex/projects/<repo>/.worktrees/<task-slug>`) on an allocated port; primary
checkouts are loading docks. History cut from this page:
[`../archive/worktrees-2026-09-25.md`](../archive/worktrees-2026-09-25.md).

## Fresh Worktree Checklist

**Steps 1-3 are what `bin/task begin` automates** (`bin/task begin --title "Three To Five Words" --repo <app> --agent <soul> …`;
resume with `bin/task begin <task-slug>`). Steps 4-9 apply either way.

1. **Create the desk** — `bin/agent-worktree new <app> <task-slug>` cuts `feat/<task-slug>`
   from the base ref (`accepted`, else `release`, else `main`), copies the primary's `.env`
   and `.env.development` (with a freshly generated dev `SECRET_KEY_BASE`, never the
   primary's: [`credentials.md`](credentials.md#local-env-files-hold-development-keys)),
   writes `.env.agent-stack`, provisions the isolated test DB, and builds
   `app/assets/builds/tailwind.css`.
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

The request survives `bin/submit`; the window closes at `reviewed`. **The desk is NOT yet
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
- `list`, `doctor`, `snapshot` and the sweeps see **every worktree git registered** for a
  repo (`git worktree list`), wherever it lives: `<repo>/.worktrees/`, a sibling
  `<repo>.worktrees/`, `<projects>/.worktrees/<repo>/`, a scratchpad. Each is labelled with
  its real repo; a desk outside `.worktrees/` usually has no port or stack.
- `doctor` reports drift and **prunable** worktrees, registered but deleted on disk (prune
  with `git -C <repo> worktree prune`).
- `remove <app> <desk>` finds the desk by its real directory name first (`qa_env` stays
  `qa_env`), normalizes only when nothing matches, and refuses a name two trees share; pass
  the path then. A path must be one of the app's desks, and never the primary checkout.
- `snapshot --write` writes the non-secret cross-app registry to
  `/Users/alex/projects/.agents/worktree-registry.json` (override `AGENT_WORKTREE_REGISTRY`).
- `cleanup` is a dry run: clean candidates merged into, or diff-equivalent to, the base ref,
  each with its safety class, `rationale:` line, and exact `remove … --yes` command. That
  dry run is the approval packet.
- `cleanup --write` files candidates on the **desk ledger** (`DeskRecord`, Desks panel on
  [/deployments](https://mcritchie.studio/deployments)). A teardown files its record
  **before** destroying anything, so **when the board is unreachable the teardown
  REFUSES**. [`../maintenance/delete-later.md`](../maintenance/delete-later.md) is history.
- The ledger tracks **managed desks only** (the root rule lives once, in `lib/desk_root.rb`).
  `snapshot` marks each desk `managed: true|false` and counts the rest as `unmanaged`; the
  board lists those but opens no ledger record for them, and closes an older open record
  for an unmanaged path once the path leaves the snapshot (`removed`, source `snapshot`). A
  **managed** desk that leaves without a teardown record stays open and is reported as
  vanished on the Desks panel; that report is the defect detector.

### The reclaim safety rule

A fresh desk and a merged one are **git-identical**, so git alone never frees a desk.
**Six independent channels** decide, through ONE decision every path shares
(`reclaim_verdict`), as an `||` chain, in order:

1. **ORIGIN** (`origin_hold`) — a gone or unreachable remote withholds.
2. **CLAIM** (`claim_hold`) — an old lease row, if any; `_ship`/`_gate` are held by ANY live
   `ReleaseConductorClaim` (`assembler` + `deployer`). A desk on a **discovered repo**
   (studio-engine, turf-vault) has no task to read, so it is judged by **git**
   (`discovered_git_hold`): clean tree, no commit off every remote (`git rev-list --count
   HEAD --not --remotes` is 0), HEAD merged into origin's default branch or its PR merged,
   and no open PR (an unanswerable `gh` holds; there is no board record to fall back on).
   A failed check returns its reason as a **short-circuit**: the later channels never run
   at all. A passed one falls through, so the DESK and PR channels still judge it. Its
   `_ship`/`_gate` workspaces are always withheld. **A gem desk has no board stage**, so it
   gets no mid-release hold: it frees once its HEAD is merged and pushed and it has sat idle.
   A "merged PR" counts only when that PR's head commit is the desk's HEAD.
3. **STAGE** (`stage_hold`) — frees a bound desk only at `shipped` or `archived`, failing
   closed on an unreadable board (withholding defers; freeing is irreversible).
4. **REVIEW** (`review_hold`) — a reviewer on the task (`review_in_progress`) holds it.
5. **DESK** (`desk_hold`) — desk age under `ClaimLease::DESK_IDLE_SECONDS` (1h29m), recent
   mtimes (`DeskActivity.touched_since?`), or the holder's gate in flight. Every unknown holds.
6. **PR** (`pr_hold`) — an open, unmerged PR holds; with `gh` unreachable the board's
   `pr_url` without a `merged` stamp holds.

Two checks sit outside the chain. A desk **outside a managed root** (`<repo>/.worktrees/`,
`<repo>.worktrees/`), such as `.claude/worktrees/*` or a scratchpad checkout, is listed but
never nominated; remove it deliberately. And a desk every channel cleared is still held when
**gitignored work** (an edited `.env.local`, say) changed after the desk was cut, because
`git status` cannot see it. Regenerable paths (`tmp/`, `log/`, `node_modules/`, builds) and
the env files this script writes do not count.

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

`move … building`, `begin` and `bin/submit` **refuse** only when another live session's bound
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
MUT="$(mktemp -d)/mut-<slug>"
git worktree add "$MUT" --detach <pr-head> &&
  cp <desk>/.env.test.local "$MUT"/ &&
  test -s "$MUT/.env.test.local" &&
  (cd "$MUT" && RAILS_ENV=test bin/rails test:prepare) ||
  echo "STOP: setup failed (no .env.test.local?); run nothing in $MUT"
# done: git worktree remove --force "$MUT"
```

- **Cut it in the scratchpad, carry `.env.test.local`, and build the assets.** The block
  is one `&&` chain on purpose: if any link fails, nothing after it runs and the last line
  says STOP. It carries no inline comments, because an interactive zsh without
  `interactivecomments` reads a `#` as an argument.
- **`.env.test.local` is untracked**; without it the throwaway runs on the SHARED test DB.
  Outside `.worktrees/`, `bin/lib/desk_guard.rb` (the pre-flight's test-DB check, loaded
  only by `bin/fast-check`) never sees the tree, so the `test -s` link is that check, and
  a missing file stops the chain before `test:prepare`.
- **Every rails command in the throwaway carries `RAILS_ENV=test`.** A bare `bin/rails`
  boots the development env, whose database is the SHARED `mcritchie_studio_development`.
  `DeskDatabaseGuard` (`lib/desk_database_guard.rb`) refuses that boot in any linked git
  worktree of the hub (a desk or a scratch throwaway; only the primary checkout is exempt),
  so a bare command aborts rather than writes, but it does not guard the TEST database and
  does not run in the satellites. `ALLOW_SHARED_DEV_DB=1` overrides it.
- **Cut it in your session scratchpad, never under `.worktrees/`.** Anything there is a
  managed desk (`lib/desk_root.rb`) with a desk-ledger episode, and removing it with plain
  git leaves a `vanished` ghost on the Desks panel. One already cut there comes down with
  `bin/agent-worktree remove <app> <name> --yes`.
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
| Shared-dev-DB refusal | `DeskDatabaseGuard`, a hub initializer | A development-env rails boot in any linked worktree of the hub (desk or scratch throwaway) whose database resolves to the shared dev DB |
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

`save` refuses, without `--force`, to overwrite a backup that differs from the file,
so a re-save after edits changes nothing and the next `restore` reverts them. Never
silence its output. The scratchpad itself does not survive the session: hand work on
by committing it to the desk branch or inlining it in the task's `agent_context`, and
park stranded work on a pushed `rescue/<slug>-<date>` branch.

## Desk Traps

- **Read current truth from `origin/accepted`, never a primary.** A primary sits on
  `main`, often far behind; a miss there means "not shipped yet", and a version read
  from its tree describes its last fetch. Use `git show origin/accepted:<path>` or
  your desk. A doc merged to `accepted` reaches Alex's primary only at a production ship.
- **Commit as soon as a coherent change exists.** A peer who claims the same task
  lands at the same path and a takeover resets it; uncommitted work is unrecoverable.
- **Confirm the database before trusting a hand-run data command:**
  `bin/rails runner 'puts ActiveRecord::Base.connection_db_config.database'`. A
  satellite desk without `.env.development.local` reaches the shared
  `<app>_development`, and no guard there refuses it.
- **A seed that fails its network fetch aborts `up` before the server starts**, and
  the seeds after it never run. Re-run `up` (the existing DB migrates and skips
  seeds) and load any later seed you need by hand.
- **`db:prepare` can dump a sibling's migration into `db/schema.rb`.** If your branch
  adds no migration, `git checkout origin/accepted -- db/schema.rb` before shipping.
- **`up` accepts a server that is already running, and a dev server never reloads
  gems.** After a gem bump, `down` then `up`, and before a demo fetch a string only
  your change contains.
- **A fresh tree lacks every gitignored artifact.** When a failure's own control fails
  too, reproduce it at the same SHA in a known-good tree before calling it a finding.
- **A vanished desk after a merge is usually the normal teardown.** Ask the remote:
  `git ls-remote --heads origin feat/<slug>`, the PR state, `bin/task show <slug>`.
- **`remove --force` overrides the content guard only for a merged PR** (it needs a
  working `gh`) and never overrides the dirty guard. Rescue dirty work to a pushed
  `rescue/<slug>-<date>` branch first.
- **On a full band, read why before provisioning:** group the withheld reasons from
  `cleanup --reclaim`. Desks held by the idle clock free themselves within the window
  (a fleet-wide board write resets it everywhere at once). Never reclaim a `_ship`
  workspace or a reviewer's throwaway.

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
