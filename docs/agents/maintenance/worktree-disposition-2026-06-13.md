# Worktree Disposition - 2026-06-13

Scope: visible sibling worktrees under `/Users/alex/projects`.

Method:

- Fetched remotes for `turf-monster`, `mcritchie-studio`, and `turf-vault`.
- Compared each worktree against `origin/main`.
- Checked dirty state with `git status --porcelain`.
- Checked whether each worktree `HEAD` is already contained in `origin/main`.
- Checked `git cherry origin/main HEAD` to find patch-equivalent commits.

## Removed In This Cleanup

These worktrees were clean and safe to remove with `git worktree remove`.

| Path | Branch | Reason |
| --- | --- | --- |
| `/Users/alex/projects/turf-monster-allow-browser-preview-fix` | `feat/allow-browser-preview-fix` | Clean; one ahead commit is patch-equivalent to `origin/main` (`git cherry` showed `-`). |
| `/Users/alex/projects/turf-monster-compliance` | `feat/underwriting-compliance` | Clean; `HEAD` contained in `origin/main`. |
| `/Users/alex/projects/turf-monster-cosign-entry-validation` | `security/cosign-entry-validation` | Clean; `HEAD` contained in `origin/main`. |
| `/Users/alex/projects/turf-monster-entry-confirmed-spinner` | `feat/entry-confirmed-spinner` | Clean; `HEAD` contained in `origin/main`. |
| `/Users/alex/projects/turf-monster-paypal` | `feat/paypal-reconcile` | Clean; `HEAD` contained in `origin/main`. |
| `/Users/alex/projects/turf-monster-phantom-signing-order` | `feat/phantom-signing-order` | Clean; `HEAD` contained in `origin/main`. |
| `/Users/alex/projects/turf-monster-quest-mailing-list` | `feat/quest-mailing-list` | Clean; `HEAD` contained in `origin/main`. |
| `/Users/alex/projects/turf-vault-v024-mainnet` | `feat/v0.24-mainnet` | Clean; `HEAD` contained in `origin/main`. |

These stray non-worktree directories contained no files at final check and were
removed with `rm -rf`:

- `/Users/alex/projects/turf-monster-cdp`
- `/Users/alex/projects/turf-monster-og-config`

## Kept For Follow-Up

These worktrees still contain unique commits or dirty files. Do not remove them
until the useful work is merged, cherry-picked, archived, or explicitly dropped.

| Path | Branch | State | Disposition |
| --- | --- | --- | --- |
| `/Users/alex/projects/turf-monster-admin-error-logs` | `feat/admin-error-logs` | Clean; `behind=94`, `ahead=2`, `plus=2` | Keep. Adds read-only admin error logs UI and tests. Candidate to review/merge or intentionally drop. |
| `/Users/alex/projects/turf-monster-dashboard-dropdown-link` | `feat/dashboard-dropdown-link` | Clean; `behind=94`, `ahead=1`, `plus=1` | Keep. Small dropdown link change; likely superseded by later nav work but not patch-equivalent. |
| `/Users/alex/projects/turf-monster-docs-worktree-stack` | `feat/docs-worktree-stack` | Clean; `behind=94`, `ahead=1`, `plus=1` | Keep until its useful worktree guidance is confirmed promoted to neutral docs. |
| `/Users/alex/projects/turf-monster-quest-navbar-cleanup` | `feat/quest-navbar-cleanup` | Clean; `behind=94`, `ahead=1`, `plus=1` | Keep. Larger navbar cleanup; compare against current UI before dropping. |
| `/Users/alex/projects/turf-monster-welcome-email` | `feat/newsletter-welcome-email` | Clean; `behind=27`, `ahead=7`, `plus=6` | Keep. Large email/outbox/catalog work; likely overlaps with current shared-email direction. Needs salvage review before deletion. |
| `/Users/alex/projects/mcritchie-studio-broadcasts` | `feat/broadcasts` | Dirty; `behind=7`, `ahead=2`, `plus=2` | Keep. Large broadcasts/email platform work plus dirty `docs/agents/system/email-delivery.md`. |
| `/Users/alex/projects/turf-vault-grant-seeds` | `feat/v0.22-grant-seeds` | Dirty; `HEAD` contained in `origin/main`; dirty `Cargo.lock` | Keep until dirty `Cargo.lock` is reviewed. |

## Next Decisions

1. Review or drop the four smaller clean Turf worktrees with unique commits.
2. Salvage or intentionally abandon the two large email-related worktrees:
   `turf-monster-welcome-email` and `mcritchie-studio-broadcasts`.
3. Review the dirty `turf-vault-grant-seeds/Cargo.lock`.
