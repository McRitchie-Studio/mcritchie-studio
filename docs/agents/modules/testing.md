# Testing

Use the smallest verification that proves the change, then broaden when the touched surface has shared behavior or money/security risk.

## Test Suite Genres

Record the expected genre in the task-board `test_plan` before implementation,
then update it with the checks actually run during handoff.

| Genre | Target | Mutates data | When to run |
|---|---|---:|---|
| Unit/model/controller CI | Local repo or CI | No | Every PR with code changes |
| Local browser smoke | Worktree URL | Yes, local DB only | UI, auth, task, contest, or navigation changes |
| Local integration | Worktree services | Yes, local DB/Redis only | Sidekiq, Redis, mail capture, and cross-service behavior |
| QA read-only smoke | Stable QA URL | No | After every QA deploy |
| QA mutating smoke | Stable QA URL | Yes, QA/devnet only | Contest, wallet, Solana, seed, or stateful flow changes |
| Devnet on-chain smoke | Devnet | Yes, devnet resources | Solana or contract integration changes; manual/nightly |
| Production read-only smoke | Production URL | No | After approved production deploy |
| Production live-email smoke | Production URL | Sends real email | Explicit operator approval only |

The `/devops` page in McRitchie Studio is the visual catalog for app-specific
commands and triggers. Update `config/devops_test_suites.yml` when a suite,
trigger, or deploy-smoke command changes.

## McRitchie Studio

```bash
bin/rails test
npm test
```

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
