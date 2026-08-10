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

These worktrees survived the first classification pass but were removed during
the salvage pass after comparing their useful work against current `main`.

| Path | Branch | Reason |
| --- | --- | --- |
| `/Users/alex/projects/turf-monster-admin-error-logs` | `feat/admin-error-logs` | Superseded by current `turf-monster/main`, which already includes the admin error log controller, routes, helper, views, and tests. |
| `/Users/alex/projects/turf-monster-dashboard-dropdown-link` | `feat/dashboard-dropdown-link` | Superseded by current `turf-monster/main`, which already includes the admin dashboard dropdown link. |
| `/Users/alex/projects/turf-monster-docs-worktree-stack` | `feat/docs-worktree-stack` | The only useful worktree guidance was Claude-specific; neutral guidance now lives in McRitchie Studio agent docs. |
| `/Users/alex/projects/turf-monster-quest-navbar-cleanup` | `feat/quest-navbar-cleanup` | Superseded by current `turf-monster/main`, which already includes the slim admin dropdown, link hub cleanup, and vault state work. |
| `/Users/alex/projects/turf-monster-welcome-email` | `feat/newsletter-welcome-email` | Obsolete relative to current `turf-monster/main`, which already has `EmailDelivery`, `EmailCatalog`, admin email review surfaces, welcome newsletter mail, and shared SES direction. Merging this branch wholesale would revert newer work. |

After `git worktree remove`, `/Users/alex/projects/turf-monster-welcome-email`
left an empty wrapper containing only `tmp/`; that wrapper was removed with
`rm -rf`.

These stray non-worktree directories contained no files at final check and were
removed with `rm -rf`:

- `/Users/alex/projects/turf-monster-cdp`
- `/Users/alex/projects/turf-monster-og-config`

## Preserved For Future Salvage

These worktrees still contain unique or dirty historical work. They were moved
under app-owned hidden `.worktrees` directories so `/Users/alex/projects` stays
usable as the clean cross-repo launch point.

| Path | Branch | State | Disposition |
| --- | --- | --- | --- |
| `/Users/alex/projects/mcritchie-studio/.worktrees/broadcasts-salvage` | `feat/broadcasts` | Dirty; old `mcritchie-studio` snapshot with 2 unique commits and dirty `docs/agents/system/email-delivery.md`. | Preserve for targeted review only. Do not merge wholesale because it predates the current agent docs and tooling. If useful, cherry-pick or reimplement the broadcasts/email concepts into current `main`. |
| `/Users/alex/projects/turf-vault/.worktrees/grant-seeds-salvage` | `feat/v0.22-grant-seeds` | Dirty `Cargo.lock`; branch `HEAD` is already contained in `origin/main`. | Preserve for historical review only. The dirty lockfile references older package state and should not be promoted without comparing against current `turf_vault` `0.25.0`. |

## Salvage Closeout - 2026-06-14

The two preserved hidden worktrees were reviewed again after the final ecosystem
closeout.

| Path | Result |
| --- | --- |
| `/Users/alex/projects/mcritchie-studio/.worktrees/broadcasts-salvage` | Worktree removed. Do not merge branch `feat/broadcasts` wholesale. The branch still has useful product direction for a future self-owned broadcast system, but it predates the current agent docs and would delete newer tooling if merged directly. The durable direction was promoted into `docs/agents/modules/email-operations.md`; keep branch `feat/broadcasts` / `origin/feat/broadcasts` as historical source material if needed. |
| `/Users/alex/projects/turf-vault/.worktrees/grant-seeds-salvage` | Worktree removed and local branch `feat/v0.22-grant-seeds` deleted. No durable content remained. The only dirty change was `Cargo.lock` changing `turf_vault` from `0.20.0` to `0.24.0`; current `main` has newer verification and deployment docs. |

## Result

`/Users/alex/projects` should now contain only primary project directories and
root-level bootstrap files. New parallel work should use each repo's hidden
`.worktrees` directory, usually through `mcritchie-studio/bin/agent-worktree`.

Remaining decision:

1. Decide whether branch `feat/broadcasts` should become a current product
   feature. If yes, reimplement or cherry-pick narrowly from the branch on top
   of current `main`; do not merge the old branch wholesale.
