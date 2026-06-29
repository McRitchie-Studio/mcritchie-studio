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

| Lane | Target | Mutates data | Blocks merge | When to run |
|---|---|---:|---:|---|
| PR review gate | Local repo or CI | Usually no | Yes | Every PR with code changes; includes lint, security scans, Rails tests, and focused browser checks for touched UI |
| Local proof | Worktree URL | Local DB only | Usually yes | UI, auth, task, contest, navigation, email capture, Redis, or worker changes |
| QA acceptance | Stable QA URL | QA/devnet only when named | No; blocks production promotion | After every QA deploy; runs task acceptance criteria against the merged result |
| Production smoke | Production URL | No by default | N/A | After approved production deploy; verifies health and key read-only routes |
| Nightly/deep | Dedicated local/QA/devnet target | Often yes | No | Full Playwright suite, devnet/on-chain, browser matrix, longer seeded workflows |
| Quarantine | Any | Varies | No until fixed | Known flaky or unrelated checks that still matter but should produce follow-up tasks instead of blocking unrelated PRs |

If a lane fails, record the classification in task `qa_feedback`:

- real regression
- unrelated existing failure
- flaky infrastructure
- stale branch
- missing seed or test data
- dependency ordering issue

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
> configures Codex's `shell_environment_policy` so new Codex Bash tools prepend
> `/opt/homebrew/opt/ruby@3.3/bin:/opt/homebrew/lib/ruby/gems/3.3.0/bin`.
> `bin/agent-runtime doctor` verifies the Codex config, current `ruby`, Bundler,
> and Rails boot path. If an already-open session still resolves system Ruby 2.6,
> restart Codex or temporarily run
> `export PATH="/opt/homebrew/opt/ruby@3.3/bin:$PATH"`. Parallel test workers
> fork-clone the test DB, which **deadlocks or segfaults the `pg` gem on macOS**
> (a Ruby crash report, not a test failure) — pg fork-safety. So as of PR #169 the
> suite runs **single-process locally by default** (`test_helper.rb` →
> `TestParallelism.worker_count`: parallel only when `CI` is set; `PARALLEL_WORKERS`
> overrides), so a plain `bin/rails test` is reliable locally while CI keeps the
> parallel speedup. `bin/agent-worktree test <app> <slug>` also runs single-process
> **and clears orphaned `rails test` procs first** — a killed/hung run leaves
> workers holding the test DB and deadlocks the next run (otherwise
> `pkill -f "rails test"`, never the dev server). Don't pipe a run through `| tail`
> (it buffers to EOF, so a hang looks identical to "working") — write to a logfile.

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
