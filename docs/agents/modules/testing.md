# Testing

Use the smallest verification that proves the change, then broaden when the
touched surface has shared behavior or money/security risk. Do not treat
"Playwright shard failed" as one undifferentiated verdict; classify which lane
failed and whether that lane blocks the current stage.

## Task Test Metadata

Tasks separate planned checks from completed checks:

- `devops.test_plan` is the expected verification plan captured before or
  during implementation.
- `devops.checks_run` is the actual verification evidence recorded during PR,
  QA, and release handoff.

Feature agents fill `test_plan` before coding and update `checks_run` before
moving to `submitted`. Avi and release conductors append QA and production
checks to `checks_run` as each stage completes.

## Test Lanes

| Lane | Target | Mutates data | Blocks merge | Gate | When to run |
|---|---|---:|---:|---|---|
| PR review gate | Local repo or CI | Usually no | Yes | G1 Cert (builder cert + dor verdict) · G2 Review (the review wave) | Every PR with code changes; includes lint, security scans, Rails tests, and focused browser checks for touched UI |
| Local proof | Worktree URL | Local DB only | Usually yes | G1 Cert (builder evidence) | UI, auth, task, contest, navigation, email capture, Redis, or worker changes |
| QA acceptance | Stable QA URL | QA/devnet only when named | No; blocks production promotion | G3 Candidate | After every QA deploy; runs task acceptance criteria against the merged result |
| Production smoke | Production URL | No by default | N/A | G4 Ship (the seal — non-blocking) | After approved production deploy; verifies health and key read-only routes |
| Nightly/deep | Dedicated local/QA/devnet target | Often yes | No | — | Full Playwright suite, devnet/on-chain, browser matrix, longer seeded workflows |
| Quarantine | Any | Varies | No until fixed | — | Known flaky or unrelated checks that still matter but should produce follow-up tasks instead of blocking unrelated PRs |

The Gate column names the branded testing gate whose attempt records that
lane's verdicts — attempt-aware GateRun rows with per-SOP results, rendered on
the task gates card (G1/G2) and the /deployments columns (G3/G4). The four
standalone gate docs live in [`gates/`](gates/g1-cert.md): `g1-cert.md`,
`g2-review.md`, `g3-candidate.md`, `g4-ship.md`.

If a lane fails, record the classification in task `qa_feedback`:

- real regression
- unrelated existing failure
- flaky infrastructure
- stale branch
- missing seed or test data
- dependency ordering issue

## A Test Whose Child Resolves The Session Must Null It

**The rule.** A test that spawns a child able to resolve `SessionIdentity` —
any `bin/` command, or anything else that reads the session env — must build
the child's env through the shared neutralizer:

```ruby
require_relative "../support/session_env"   # standalone minitest files
                                            # (test_helper requires it for Rails-side tests)

env = SessionEnv.neutralized("FOO" => "bar")            # FOO set, session UNSET
out = IO.popen(env, cmd, &:read)
Open3.capture2(SessionEnv.neutralized, *cmd)            # bare overlay
SessionEnv.neutralized("CLAUDE_CODE_SESSION_ID" => sid) # opt IN to a fake session
```

Session-blind spawns are exempt: `git` reads no session var, so the tests that
shell out to it (`fast_cert_test`, `repo_root_test`) rightly skip the
neutralizer. Backticks and `%x` take no env hash at all — use them only for
session-blind children, and switch to a spawner that can pass an env before the
child grows session-aware. When unsure, neutralize. The one spawn that must stay
bare is one that deliberately asserts session inheritance (`Release::GateEnvTest`).

**Why.** An interactive Claude session exports `CLAUDE_CODE_SESSION_ID` (Codex:
`CODEX_THREAD_ID`); **CI and a plain shell export neither.** A spawned `bin/task`,
`bin/fast-check`, `bin/dor-check`, `bin/pr-review` or `bin/agent-activity`
inherits the var, so `SessionIdentity` (`bin/lib/session_identity.rb`) resolves
the **operator's live session** where CI resolves none. Actor/persona defaulting
takes the wrong branch and best-effort narration shells out to the real board
mid-test — so the test **false-fails for the agent running it by hand, while
staying green on CI.** That asymmetry is what hides the coupling: this bug class
was independently rediscovered at least three times, and once red-flagged
genuinely-green code at a release gate. Green on CI is not proof; run the suite
from a live agent session.

**`nil` means UNSET — never `""`.** A nil value removes the key in the child
(`Process.spawn` semantics). A literal empty string is still **exported**:
`SessionIdentity` happens to treat a blank id as absent, but any reader keying on
*presence* (`ENV.key?`, a shell's `${VAR+set}`) sees a session that isn't there.
`SessionEnv.neutralized` normalizes a blank session override to unset for you.

**Two neutralizers, held in lockstep by a test — not by trust.** `SessionEnv`
(`test/support/session_env.rb`) covers tests, including an agent running
`bin/rails test` by hand in a worktree. `Release::GateEnv`
(`app/models/release/gate_env.rb`) covers the release gate's own spawn env. They
are deliberately not shared code — `SessionEnv` must load in a bare
`minitest/autorun` file with no Rails — and the dependency runs **one way only**:
a test may require `Release::GateEnv` (it is pure and Rails-free by construction,
exactly as `bin/release.rb` requires it), but production code never reaches into
`test/`.

That leaves one real hazard, **drift between the two key lists**, and it is closed
mechanically rather than by prose: `SessionEnvTest`
(`test/lib/session_env_test.rb`) requires `Release::GateEnv`, asserts the two
`SESSION_KEYS` lists are **equal**, and asserts every production key is genuinely
absent from a spawned child. Add a key to **either** list alone and the suite goes
red — so add it to both. Each side's nil-means-unset semantics is covered by its
own test (`SessionEnvTest`, `Release::GateEnvTest`).

**Pin a drift guard against the live constant, never a literal copy of the list.**
A literal only pins the side it is written on, so the *other* side can grow a key
while every check stays green — which is exactly the leak these helpers exist to
prevent.

## Running Tests By Path Skips The Asset Build

`bin/rails test test/models/widget_test.rb` does **not** behave like a bare
`bin/rails test`. Rails runs its `test:prepare` task only when **no argument
looks like a path** — `Rails::Command::TestCommand` guards it with
`run_prepare_task if self.args.none?(EXACT_TEST_ARGUMENT_PATTERN)`, and that
pattern matches file paths and `-n`/`--name` filters. `test:prepare` is the
standard hook a CSS/JS bundler enhances (`tailwindcss-rails` does
`Rake::Task["test:prepare"].enhance(["tailwindcss:build"])`), and it is the only
thing that builds `app/assets/builds/tailwind.css`. **`db:test:prepare` does not
build it** — tailwindcss enhances that task only as a fallback, for apps where
`test:prepare` is undefined, which it never is in a Rails app.

`app/assets/builds/` is **gitignored** (only `.keep` is tracked), so every virgin
checkout starts with no built CSS. Put those two facts together:

| Runner | Invocation | `test:prepare` runs? | Virgin tree |
|---|---|---|---|
| GitHub CI | `bin/rails db:test:prepare test test:system` (rake `test` shells an **argless** `rails test`) | yes | green |
| `bin/full-suite-check` | `bin/rails test` (argless) | yes | green |
| Release gate workspace — **hub** | `bin/rails db:test:prepare test test:system` (the hub's registry `test_cmd`/`qa_test_cmd` — rake-routed, and rake's `test` shells an **argless** `rails test`) | yes | green |
| Release gate workspace — **satellites** | `bin/rails test test/integration` (`qa_test_cmd`, `config/release_repos.yml`) | **no** | green — the gate preps the env itself (PR #522) |
| **`bin/fast-check`** | `bin/rails test <mapped/spine paths>` | **no** | **was red** |
| A hand-run single file | `bin/rails test test/x_test.rb` | **no** | **was red** |

The red is `The asset "tailwind.css" is not present in the asset pipeline` on
every view-rendering test — dozens of errors on a diff that never touched a
view, which reads as a phantom regression. The two runners this repo owns now
prepare the test env themselves — `bin/fast-check`'s `test-prepare` lane, and
`bin/agent-worktree`'s `prepare_test_env` (run by `new` at bringup, by `up`, and
by `test <file>`) — so their failure is designed out rather than documented
around.

**The release gate workspace was fixed the same way** (task
`gate-workspace-skips-test-prepare`, PR #522, shipped): `prepare_gate_workspace!`
(`bin/release.rb`) now runs `bin/rails db:test:prepare test:prepare` before both
the G3 and G4 lanes, so a `.worktrees/_gate` — created virgin by
`git worktree add --detach` — has its bundled assets built whatever shape the
registered command takes, the satellites' path-arg `qa_test_cmd` included.
(turf-monster was the live exposure: `tailwindcss-rails`, gitignored
`app/assets/builds/*`, `stylesheet_link_tag "tailwind"` via studio-engine's head
partial — its G3 gate took exactly this false red before #522.) With the prep in
place, a gate red on a missing asset is no longer this bug: `test:prepare`
builds the stylesheet up front, so treat such a red as a real signal — most
plausibly a broken stylesheet in the release's own diff (a bad `@apply`, an
unknown utility, a malformed `@theme`) — and read the gate's captured output to
tell an env gap from a diff regression.

Two rules follow:

- **A cert lane that hits an ENV gap must say so, not fail as a test.** A gate
  that red-flags green code teaches agents to distrust and route around it. The
  inverse lies too: do not report a real diff regression (a broken stylesheet
  fails the asset build) as an ENV gap.
- **If you add a lane that runs tests by path** (anywhere: a new bin script, a
  gate workspace, a CI job that shards by file), prepare the test env first —
  `bin/rails db:test:prepare test:prepare`, one boot. `test/lib/tasks/test_prepare_asset_hook_test.rb`
  pins the hook that makes this work.

## A Test May Never Write The Operator's Real `.agents` State

The `bin/` stack keeps two stores **outside** the repo, under the real projects
root, and both are resolved by **fallback**:

| store | pinned by | falls back to |
|-------|-----------|---------------|
| usage/cost baselines | `TASK_USAGE_DIR` | `<projects>/.agents/task-usage` |
| session marker | `CLAUDE_PROJECTS_DIR` | `<projects>/.agents/sessions` |

A test that spawns `bin/task`, `bin/release` or `bin/reviewer-select` and pins
neither hands its child the **operator's live store**. This is not theoretical:
`task_cli_test.rb` pinned neither, its `SESSION` constant is a **real past
session id** whose 30MB transcript still sits in `~/.claude` (HOME was unpinned
too), and so `bin/task create` under the suite globbed that transcript and wrote
its ~1.9-billion-token totals into the real cost store under the stub slug
`demo-task`. Measured `$cost` derives `actual_size` and seeds the reviewer-select
baselines, so a fixture row skews the sizing intelligence.

**The rule, in two halves — you need both.**

- **Configured.** Pin all three (`TASK_USAGE_DIR`, `CLAUDE_PROJECTS_DIR`, `HOME`)
  into a tmpdir. `TaskUsageSandboxEnv.child_env(tmpdir)` builds them:

  ```ruby
  env = SessionEnv.neutralized(TaskUsageSandboxEnv.child_env(root).merge("FOO" => "1"))
  ```

  `HOME` is not optional — it is the **read** half. An unpinned HOME lets a child
  glob whatever real transcript matches its fixture session id.

- **Asserted.** Requiring `test/support/session_env.rb` arms `TASK_USAGE_SANDBOX`
  for the whole test **process**, and Ruby hands a process's env to every child it
  spawns — so *every* test child inherits it, including one written years from now
  by someone who never read this page. With the sandbox on, `TaskUsageSandbox`
  (`lib/task_usage_sandbox.rb`) makes the CLI **fail closed**: an unpinned store
  **aborts** the command instead of falling back, and any resolved path inside the
  real `<projects>/.agents` is refused whatever pointed it there. A pin you have
  to *remember* is the bug; the guard is the half that cannot rot.

A violation exits via `abort` (SystemExit) **on purpose**. Every caller of this
state is best-effort (`rescue StandardError => nil`, so a usage hiccup can never
kill a stage transition), and a violation raised as a `StandardError` would be
swallowed by exactly those rescues — a guard that degrades to a silent no-op is
not a guard.

**In-process writers need the pin too — not only spawned children.** Rule 1
checks the **ENV pin** at the write seam, even for a write aimed at an explicit
tmpdir `dir:` — by the time a path reaches `TaskUsageBaseline#write`, a CLI's
env-fallback dir looks exactly like a test's explicit one, so the pin is the only
tell the guard has. A test that calls the baseline **in the test process** (e.g.
`task_usage_baseline_test.rb`) must set `ENV["TASK_USAGE_DIR"]` to a tmpdir in
`setup` and restore it in `teardown`, or its first write aborts the whole
combined `bin/rails test` run — green alone, red in any process where a sibling
file armed the sandbox.

**Finding what already leaked.** `bin/task usage-audit` is a read-only sweep of
the store for rows keyed by a slug only a test stub serves (`demo-task`,
`cli-board-sample`). It reports and exits 2; it never purges — a baseline is
indistinguishable at the file level from real operator state, so removing one is
the operator's call. Note the signal is the **slug, not the size**: a stored row
is the session's *cumulative* totals, so a long real session banks a
billion-token baseline legitimately and magnitude proves nothing.

## Test Suite Catalog

`bin/devops-tests` reads `config/devops_test_suites.yml`. Each suite should
include:

- `lane`: `pr_review_gate`, `local_proof`, `qa_acceptance`,
  `production_smoke`, `nightly_deep`, or `quarantine`
- `environment`: local, QA, devnet, or production target
- `trigger`: when the suite should run
- `command`: the command or command template
- `blocks_merge`: true only for PR review gates that should prevent merge
- `mutates`: true when it creates or changes data
- `notes`: risk and setup context

Update the catalog when a suite, trigger, deploy-smoke command, or app joins
the managed stack. Fresh Avi sessions can run:

```bash
bin/devops-tests --app turf-monster
bin/devops-tests --app mcritchie-studio --lane pr_review_gate
bin/devops-tests --lane qa_acceptance
```

## McRitchie Studio

```bash
bin/rails test
npm test
```

> **Running the Rails suite from an agent shell.** `bin/agent-runtime install`
> manages a small `~/.zprofile` Ruby PATH block so Codex Bash tools and other
> non-interactive zsh login shells prepend
> `/opt/homebrew/opt/ruby@3.3/bin:/opt/homebrew/lib/ruby/gems/3.3.0/bin` while
> preserving normal command lookup. `bin/agent-runtime doctor` verifies the zsh
> startup file, login-shell `ruby`, Bundler, and Rails boot path. If an
> already-open session still resolves system Ruby 2.6, restart Codex or
> temporarily run
> `export PATH="/opt/homebrew/opt/ruby@3.3/bin:$PATH"`. Parallel test workers
> fork-clone the test DB, which **deadlocks or segfaults the `pg` gem on macOS**
> (a Ruby crash report, not a test failure) — pg fork-safety. So as of PR #169 the
> suite runs **single-process locally by default** (`test_helper.rb` →
> `TestParallelism.worker_count`: parallel only when `CI` is set; `PARALLEL_WORKERS`
> overrides), so a plain `bin/rails test` is reliable locally while CI keeps the
> parallel speedup. `bin/agent-worktree test <app> <slug>` also runs single-process
> **and clears orphaned `rails test` procs first** — a killed/hung run leaves
> workers holding the test DB and deadlocks the next run. Don't pipe a run through
> `| tail` (it buffers to EOF, so a hang looks identical to "working") — write to a
> logfile. **Never `pkill -f "rails test"`**: with several agents building at once
> that reaps a SIBLING worktree's cert mid-run. Kill by pid, or let the cert's own
> orphan guard do it (below) — it is scoped to one worktree.

### The cert's orphan guard (the timeout-orphan)

A cert can outlive its harness. `bin/fast-check` on a diff that maps to ~120 test
files runs 7+ minutes — well past an agent harness's 120s Bash timeout. When that
timeout killed the cert **parent**, the `bin/rails test` **grandchild survived it**,
reparented to launchd (`PPID 1`), still holding an open connection to the worktree's
test DB:

```
PID   PPID  PGID  STAT COMMAND
41578    1  41538  R   ruby bin/rails test test/models/task_test.rb ...
pg_stat_activity: pid 41763 | idle in transaction | bin/rails
```

Every retry then died in the test-prepare lane — `db:test:purge` cannot DROP a
database another session holds:

```
PG::ObjectInUse: ERROR: database "..._test_..." is being accessed by other users
DETAIL: There is 1 other session using the database.
Tasks: TOP => db:test:load_schema => db:test:purge
```

…and the cert reported that as *"USUALLY an ENV gap … NOT a regression in your
diff"*, never **naming** the orphan. So the agent retried into the same wall: three
attempts, 35 minutes, zero board progress (live, 2026-07-13) — while its ClaimLease
heartbeat kept the task looking healthy on the board. Both cert lanes now defend
against this (`bin/lib/cert_process.rb`, `bin/lib/cert_orphan_guard.rb`):

- **Prevent** — each lane runs in its **own process group**, and the cert reaps that
  GROUP on any signal it can catch (TERM/INT/HUP) or on an exception. The suite can
  no longer outlive the cert that spawned it.
- **Detect** — a SIGKILL runs no handler, so prevention can never be complete. Each
  lane writes a runlock naming its process group **and the OS's start time for it** —
  in the repo's **git dir** (`<git-dir>/cert-run.json`; per-worktree, and invisible to
  `git status` in every repo, because a lock that must survive a SIGKILL would otherwise
  be untracked dirt and the cert refuses a dirty tree). The **next** cert reads it and,
  before any lane runs:
  - cert pid **alive and provably ours** → a real concurrent cert in this tree →
    **refuse** (never kill a live sibling; two suites on one worktree test DB corrupt
    each other's fixtures and SIGSEGV Ruby),
  - cert pid dead, group leader **alive and provably ours** → our own orphan →
    **reap the group, loudly**,
  - something alive under that pgid that is **provably NOT ours** → the OS recycled
    the number → **never kill it**; the lock is a corpse, so discard it and carry on,
  - something alive whose ownership we **cannot prove** (a lock predating this guard) →
    **refuse and name it**, and let a human decide,
  - any **other** session holding the test DB (a pre-fix orphan, a stray manual run,
    a `bin/release` gate suite) → **refuse and name it**, with the
    `pg_terminate_backend` command that clears it.

**A pgid is a recyclable integer — liveness is never identity.** The first cut of this
guard reaped on the predicate *"some process with this pgid is alive"*, and the runlock
is repo-relative (it outlives reboots), so a nine-day-old lock whose pgid the OS had
since handed to an unrelated process made the guard **kill an innocent bystander** and
report "ORPHAN REAPED" (caught in review, 2026-07-14). Identity is therefore the OS's
own start-time record (`ps -o lstart=`) for the pid — recorded at spawn, re-read and
matched exactly before any signal. The rule is: **kill only what you can prove is
yours; if you cannot prove it, refuse and say so.** A reaper that guesses is worse than
no reaper — it turns a stalled cert into a corrupted machine. (And a signal is never
aimed at pgid 0, 1, or the cert's own group: `kill(sig, -1)` means *every process you
own*, not "group 1".)

Every one of those messages says **"NOT a regression in your diff"**, because that is
what an ENV-class failure is. A cert that refuses and names the orphan is a good cert;
a cert that blames "an ENV gap" and lets you retry into a wall is the bug; a cert that
kills a process it cannot name is worse than either.

Skip the guard only in harness tests: `FAST_CHECK_SKIP_ORPHAN_GUARD=1` /
`FULL_SUITE_SKIP_ORPHAN_GUARD=1`.

## Turf Monster

```bash
bin/rails test
npm test
npm run test:parallel
```

Devnet and mainnet-adjacent flows require the app-specific runbooks in `turf-monster/e2e/DEVNET_RUNBOOK.md`, `turf-monster/docs/SOLANA.md`, and `turf-vault/docs/MAINNET_LAUNCH.md`.

## Gems And Contract

Run library tests in their owning repos when changing shared code:

```bash
cd /Users/alex/projects/solana-studio
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
```

`studio-engine` is usually verified through the consuming Rails apps.
