# Delete Later Ledger

This ledger tracks files and directories that look removable once replacement docs, merged PRs, or migration checks are complete. Do not delete from this list without confirming the condition.

> **Worktree desk rows have moved to the board. This file no longer takes them.**
> `bin/agent-worktree` used to append its teardown rows here, resolved against the hub
> checkout — and cleanups run from the **primary**, which sits on `main`, a branch nobody
> may commit to. So the audit row was created in the one place it could never be saved
> from: "restore later" stashes piled up between 2026-06-26 and 2026-08-31 carrying **166
> rows** across **twelve stashes** plus the primary's own uncommitted tree, and not one was
> ever restored. Desk records are `DeskRecord` now, on the Desks panel at
> [/deployments](https://mcritchie.studio/deployments).
>
> *(An earlier survey put this at 98 rows in six stashes. That was the count across the six
> stashes it examined; sweeping all nineteen plus the uncommitted tree found 166. Re-derive
> before quoting a number here — `bin/harvest-desk-ledger --dry-run` prints it.)*
>
> **What still belongs here:** hand-written rows for a *file or doc* that looks removable
> once some condition holds — the original purpose of this ledger, and a human write, not
> a machine one.
>
> **Do not delete this file or its archive.** They hold every desk row filed before the
> cutover, `bin/ledger-guard` still refuses a tree that lost a dated row, and they are the
> SOURCE the harvest reads: `/tasks/harvest-stranded-ledger-stashes` recovered the 166
> stranded rows from the stashed copies of these two files onto the board with
> `bin/harvest-desk-ledger`. That command stays runnable and is safe to run again — it is
> keyed on the row text, so a second pass writes nothing — and it is what to reach for if
> another stranded ledger copy ever turns up.

**Rows are moved, never deleted.** A row whose Status carries a **date** (`removed 2026-08-20`) is a teardown that already happened — immutable history. On the `archive-shipped` beat it moves to [`../archive/maintenance/delete-later-archive.md`](../archive/maintenance/delete-later-archive.md); it never leaves both files. A row with **no** date (`pending approval`, `reference only`) is an open item, and the teardown that resolves it closes that row in place.

Desk paths **recycle** — `_ship` is torn down every release cycle at the same path — so a second teardown of one path **appends a new row beside** the first. Overwriting the earlier dated row destroys a teardown record, which is what happened on 2026-08-21 (three rows, restored by zap `6c2eb98e`). The invariant is now mechanical: `bin/ledger-guard` compares this file plus its archive against git history and refuses any tree that lost a dated row, `bin/archive-docs` runs the same check at both ends of the roll, and `test/lib/ledger_guard_test.rb` runs it in CI on every PR. If it fires, recover the row with `git show <ref>:docs/agents/maintenance/delete-later.md` — do not edit the guard.

| Path | Type | Why it is a candidate | Safe-delete condition | Status |
|------|------|-----------------------|-----------------------|--------|
| `/Users/alex/.claude/projects/-Users-alex-projects/memory/*` | local memory | Local Claude memory contains useful historical feedback but should not be the durable source. | Durable lessons promoted into McRitchie Studio docs; keep local memory untouched unless the user asks. | reference only |
| `/Users/alex/.claude/agents/*.md` | local memory | Character files contain useful role expectations but are Claude-specific. | Neutral role/culture rules promoted into McRitchie Studio docs; keep local files untouched unless the user asks. | reference only |

<!-- agent-worktree cleanup 2026-06-17 -->

<!-- agent-worktree cleanup 2026-06-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/devops-scout-launcher-v1` | worktree | Hidden worktree; branch `feat/devops-scout-launcher-v1` is clean and its final diff against origin/main is empty, usually after a squash merge. | Remove with `bin/agent-worktree remove mcritchie-studio devops-scout-launcher-v1 --yes` after operator approval. | pending approval |

<!-- agent-worktree cleanup 2026-06-19 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/devops-scout-control-v1` | worktree | Hidden worktree; branch `feat/devops-scout-control-v1` is clean and its final diff against origin/main is empty, usually after a squash merge. | Remove with `bin/agent-worktree remove mcritchie-studio devops-scout-control-v1 --yes` after operator approval. | pending approval |
| `/Users/alex/projects/mcritchie-studio/.worktrees/task-board-devops-contract` | worktree | Hidden worktree; branch `feat/task-board-devops-contract` is clean and its final diff against origin/main is empty, usually after a squash merge. | Remove with `bin/agent-worktree remove mcritchie-studio task-board-devops-contract --yes` after operator approval. | pending approval |
| `/Users/alex/projects/turf-monster/.worktrees/sidebar-back-qa-sync` | worktree | Hidden worktree; branch `feat/sidebar-back-qa-sync` is clean and its final diff against origin/main is empty, usually after a squash merge. | Remove with `bin/agent-worktree remove turf-monster sidebar-back-qa-sync --yes` after operator approval. | pending approval |

<!-- agent-worktree remove 2026-06-19 -->

<!-- agent-worktree remove 2026-06-21 -->

<!-- agent-worktree remove 2026-06-25 -->

<!-- agent-worktree remove 2026-06-25 -->

<!-- agent-worktree remove 2026-06-25 -->

<!-- agent-worktree remove 2026-06-25 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-06-28 -->

<!-- agent-worktree remove 2026-07-01 -->

<!-- agent-worktree remove 2026-07-01 -->

<!-- agent-worktree remove 2026-07-01 -->

<!-- agent-worktree remove 2026-07-01 -->

<!-- agent-worktree remove 2026-07-01 -->

<!-- agent-worktree remove 2026-07-01 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-03 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-04 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-05 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-06 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-08 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-10 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-12 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- agent-worktree remove 2026-07-14 -->

<!-- manual remove 2026-07-14 — reclaim gate REFUSED; removed by hand after preserving the commits -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

## 2026-08-08 — stale unmerged desk sweep (content-on-release guard overridden, 14 desks)
Side quest with Mr. McRitchie: 14 clean-but-UNMERGED desks pinned the Redis band.
`bin/agent-worktree remove` refuses unmerged content and `--force` clears only the
merged-PR case, so these were removed manually AFTER preservation. All 14 tasks were
`[archived]` (or had no task); no live session desks touched.
- Preservation: every branch verified pushed to origin; `feat/cap-full-suite-check-parallel-workers`
  pushed fresh (was local-only); `release-gate-orphans-its-suite` local HEAD (9 diverged commits)
  preserved as tag `archive/release-gate-orphans-its-suite-local` (f32687e) — orphaned-fix review
  still owed, see parking-lot.
- Removed (redis DB flushed): hub cap-full-suite-check-parallel-workers(9),
  heartbeat-global-event-feed(10), nfl-team-totals(13), devops-sop-infographic(14),
  harden-the-devops-gate(17), worktree-new-half-builds-desk(20), release-gate-orphans-its-suite(24),
  heartbeat-span-polish(32), claim-heartbeat-evidences-progress(49), repin-studio-engine-in-mcritchie(51);
  turf suite-consistency-cleanup(19), contest-payout-polish(21), worktree-new-half-builds-desk(26);
  chain-ops suite-consistency-cleanup(16).

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-08 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-10 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-13 -->

<!-- agent-worktree remove 2026-08-15 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-18 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-19 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-21 -->

<!-- agent-worktree remove 2026-08-24 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-25 -->

<!-- agent-worktree remove 2026-08-26 -->

<!-- agent-worktree remove 2026-08-26 -->

<!-- agent-worktree remove 2026-08-26 -->

<!-- agent-worktree remove 2026-08-26 -->

<!-- clean-up Phase 4 findings 2026-08-25 — HELD, not deleted -->
| `postgres: 498 × *_development_* databases` | database | Per-worktree Postgres databases whose desk is long gone. Measured 2026-08-25: 512 per-worktree databases exist, only 14 are owned by a live desk; the other **498 total ~11.7 GB** (cluster total 41 GB). `bin/agent-worktree remove` flushes the desk's Redis DB but never drops its Postgres database, so every teardown since the beginning has left one behind. 84 of the 498 are Rails parallel-test shards (`<db>-0` … `<db>-13`). Detection was validated: no live desk's database is in the orphan set, and the two databases with live connections at measurement time (`turf_monster_development_adopt_birthday_age_gate_flow`, `mcritchie_studio_development_pin_applications_ladder_row`) were correctly spared. | NOT dropped this run, deliberately: the disk is at 32% (614 GB free of 926 GB), so ~11.7 GB is no pressure, and 498 irreversible drops is far beyond routine residue with four sessions live. Drop only with an explicit operator go-ahead AND a `pg_stat_activity` guard per database — one apparent orphan (`mcritchie_studio_development_route_last_release_animations`) showed a transient live connection during measurement. The durable fix belongs upstream in `bin/agent-worktree remove`, so a one-time sweep does not just reset a counter that climbs again. | held — needs decision |
| `/Users/alex/projects/mcritchie-studio-ai-builder-cache` | worktree | Untracked git worktree OUTSIDE any `.worktrees/` tree, flagged by `bin/agent-worktree doctor` as `orphan:…dbf07763` — not in the managed registry, so no sweep will ever reach it. Branch `feat/ai-builder-cache-run` @ c7d5d326, tree clean, created 2026-06-17. Holds **no Redis DB**, so removing it frees no band capacity. Carries **5 commits / 517 insertions across 27 files** that are not on `origin/accepted` (admin gating for builder roster controls, builder cache run keys, sticky-table fixes, 110 new lines of `builders_controller_test.rb`). No board task exists (`ai-builder-cache-run` → 404). | Code is SAFE: `origin/feat/ai-builder-cache-run` is at the identical SHA c7d5d326, zero unpushed — origin holds it, so removal loses nothing. Held anyway because it is an unresolved **orphaned-fix** question, not a capacity question: per the clean-up SOP, a branch is superseded only if you can point at the code that supersedes it, and that check has not been done for these 5 commits. Do that check, record the verdict in `parking-lot.md`, then remove. | held — needs decision |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/seed-nfl-player-database` | worktree | Hidden worktree; branch `feat/seed-nfl-player-database` is clean and HEAD 597db71 is contained in origin/accepted; health down, Redis DB 16, database turf_monster_development_seed_nfl_player_database:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/seed-nfl-player-database (GitHub asked); no live build claim on seed-nfl-player-database; no review in progress; desk idle (born 63.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster seed-nfl-player-database --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/delete-turf-layer-shim` | worktree | Hidden worktree; branch `feat/delete-turf-layer-shim` is clean and HEAD b131414 is contained in origin/accepted; health down, Redis DB 24, database turf_monster_development_delete_turf_layer_shim:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/delete-turf-layer-shim (GitHub asked); no live build claim on delete-turf-layer-shim; no review in progress; desk idle (born 52.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster delete-turf-layer-shim --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/headshot-slow-failure-fallback` | worktree | Hidden worktree; branch `feat/headshot-slow-failure-fallback` is clean and HEAD ed87d8e is contained in origin/accepted; health down, Redis DB 37, database turf_monster_development_headshot_slow_failure_fallback:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/headshot-slow-failure-fallback (GitHub asked); no live build claim on headshot-slow-failure-fallback; no review in progress; desk idle (born 28.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster headshot-slow-failure-fallback --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/contest-live-score-ranking` | worktree | Hidden worktree; branch `feat/contest-live-score-ranking` is clean and HEAD 974dbd5 is contained in origin/accepted; health down, Redis DB 12, database turf_monster_development_contest_live_score_ranking:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/contest-live-score-ranking (GitHub asked); no live build claim on contest-live-score-ranking; no review in progress; desk idle (born 66.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster contest-live-score-ranking --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/cdp-setup-reads-studio-agents` | worktree | Hidden worktree; branch `feat/cdp-setup-reads-studio-agents` is clean and HEAD 7ff0216 is contained in origin/accepted; health down, Redis DB 38, database turf_monster_development_cdp_setup_reads_agents_studio:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/cdp-setup-reads-studio-agents (GitHub asked); no live build claim on cdp-setup-reads-studio-agents; no review in progress; desk idle (born 28.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster cdp-setup-reads-studio-agents --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/suite-must-not-mutate-repos` | worktree | Hidden worktree; branch `feat/suite-must-not-mutate-repos` is clean and HEAD 7ee9e9c0 is contained in origin/accepted; health down, Redis DB 23, database mcritchie_studio_development_suite_must_not_mutate_repos:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/suite-must-not-mutate-repos (GitHub asked); no live build claim on suite-must-not-mutate-repos; no review in progress; desk idle (born 52.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio suite-must-not-mutate-repos --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/restore-codex-identity-bar` | worktree | Hidden worktree; branch `feat/restore-codex-identity-bar` is clean and HEAD 50b2f44f is contained in origin/accepted; health down, Redis DB 53, database mcritchie_studio_development_restore_codex_identity_bar:missing Cleared: merged into origin/accepted, tree clean; no open PR recorded for feat/restore-codex-identity-bar (GitHub unreachable; the bound task shows nothing unlanded); no live build claim on restore-codex-identity-bar; no review in progress; desk idle (born 23.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio restore-codex-identity-bar --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/focus-game-scorer-card` | worktree | Hidden worktree; branch `feat/focus-game-scorer-card` is clean and HEAD 195937a is contained in origin/accepted; health up, Redis DB 21, database turf_monster_development_focus_game_scorer_card:ok Cleared: merged into origin/accepted, tree clean; no open PR recorded for feat/focus-game-scorer-card (GitHub unreachable; the bound task shows nothing unlanded); no live build claim on focus-game-scorer-card; no review in progress; desk idle (born 60.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster focus-game-scorer-card --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/stamp-built-by-on-claim` | worktree | Hidden worktree; branch `feat/stamp-built-by-on-claim` is clean and HEAD 71a3732a is contained in origin/accepted; health down, Redis DB 19, database mcritchie_studio_development_stamp_built_by_on_claim:missing Cleared: merged into origin/accepted, tree clean; no open PR recorded for feat/stamp-built-by-on-claim (GitHub unreachable; the bound task shows nothing unlanded); no live build claim on stamp-built-by-on-claim; no review in progress; desk idle (born 67.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio stamp-built-by-on-claim --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/ship-must-not-exit-zero` | worktree | Hidden worktree; branch `feat/ship-must-not-exit-zero` is clean and HEAD adf924e9 is contained in origin/accepted; health down, Redis DB 55, database mcritchie_studio_development_ship_must_not_exit_zero:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/ship-must-not-exit-zero (GitHub asked); no live build claim on ship-must-not-exit-zero; no review in progress; desk idle (born 26.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio ship-must-not-exit-zero --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/stop-headers-chasing-navbar` | worktree | Hidden worktree; branch `feat/stop-headers-chasing-navbar` is clean and HEAD 7075c4aa is contained in origin/accepted; health up, Redis DB 34, database mcritchie_studio_development_stop_headers_chasing_navbar:ok Cleared: merged into origin/accepted, tree clean; no open PR recorded for feat/stop-headers-chasing-navbar (GitHub unreachable; the bound task shows nothing unlanded); no live build claim on stop-headers-chasing-navbar; no review in progress; desk idle (born 57.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio stop-headers-chasing-navbar --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/_zap-verify-recipe` | worktree | Hidden worktree; branch `` is clean and HEAD 88f37965 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no bound task, so no build claim to hold it; desk idle (born 48.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio _zap-verify-recipe --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/adopt-engine-wallet-picker` | worktree | Hidden worktree; branch `feat/adopt-engine-wallet-picker` is clean and HEAD 701671bf is contained in origin/accepted; health down, Redis DB 18, database mcritchie_studio_development_adopt_engine_wallet_picker:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/adopt-engine-wallet-picker (GitHub asked); no live build claim on adopt-engine-wallet-picker; no review in progress; desk idle (born 71.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio adopt-engine-wallet-picker --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/agent-flag-silently-drops` | worktree | Hidden worktree; branch `feat/agent-flag-silently-drops` is clean and HEAD 98f2994b is contained in origin/accepted; health down, Redis DB 57, database mcritchie_studio_development_agent_flag_silently_drops:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/agent-flag-silently-drops (GitHub asked); no live build claim on agent-flag-silently-drops; no review in progress; desk idle (born 23.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio agent-flag-silently-drops --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/consumers-fork-modal-host` | worktree | Hidden worktree; branch `feat/consumers-fork-modal-host` is clean and HEAD f81dad5a is contained in origin/accepted; health down, Redis DB 54, database mcritchie_studio_development_consumers_fork_modal_host:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/consumers-fork-modal-host (GitHub asked); no bound task, so no build claim to hold it; desk idle (born 26.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio consumers-fork-modal-host --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/correct-credential-doc-overclaims` | worktree | Hidden worktree; branch `feat/correct-credential-doc-overclaims` is clean and HEAD 8b9cd8a2 is contained in origin/accepted; health down, Redis DB 41, database mcritchie_studio_development_correct_credential_doc_overclaims:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/correct-credential-doc-overclaims (GitHub asked); no live build claim on correct-credential-doc-overclaims; no review in progress; desk idle (born 37.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio correct-credential-doc-overclaims --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/credential-prose-tells-truth` | worktree | Hidden worktree; branch `feat/credential-prose-tells-truth` is clean and HEAD 9c518e57 is contained in origin/accepted; health down, Redis DB 58, database mcritchie_studio_development_credential_prose_tells_truth:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/credential-prose-tells-truth (GitHub asked); no live build claim on credential-prose-tells-truth; no review in progress; desk idle (born 23.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio credential-prose-tells-truth --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/defork-consumer-modal-hosts` | worktree | Hidden worktree; branch `feat/defork-consumer-modal-hosts` is clean and HEAD b2c4e837 is contained in origin/accepted; health up, Redis DB 29, database mcritchie_studio_development_defork_consumer_modal_hosts:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/defork-consumer-modal-hosts (GitHub asked); no live build claim on defork-consumer-modal-hosts; no review in progress; desk idle (born 58.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio defork-consumer-modal-hosts --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/deployer-refusal-names-fix` | worktree | Hidden worktree; branch `feat/deployer-refusal-names-fix` is clean and HEAD 9e61fb9d is contained in origin/accepted; health down, Redis DB 59, database mcritchie_studio_development_deployer_refusal_names_fix:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/deployer-refusal-names-fix (GitHub asked); no live build claim on deployer-refusal-names-fix; no review in progress; desk idle (born 11.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio deployer-refusal-names-fix --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-picker-gem-path-assertion` | worktree | Hidden worktree; branch `feat/fix-picker-gem-path-assertion` is clean and HEAD a980baab is contained in origin/accepted; health down, Redis DB 22, database mcritchie_studio_development_fix_picker_gem_path_assertion:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-picker-gem-path-assertion (GitHub asked); no live build claim on fix-picker-gem-path-assertion; no review in progress; desk idle (born 63.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio fix-picker-gem-path-assertion --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/follow-1password-vault-rename` | worktree | Hidden worktree; branch `feat/follow-1password-vault-rename` is clean and HEAD 719447d1 is contained in origin/accepted; health down, Redis DB 35, database mcritchie_studio_development_follow_1password_vault_rename:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/follow-1password-vault-rename (GitHub asked); no live build claim on follow-1password-vault-rename; no review in progress; desk idle (born 39.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio follow-1password-vault-rename --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/never-cache-deployer-token` | worktree | Hidden worktree; branch `feat/never-cache-deployer-token` is clean and HEAD 3d330137 is contained in origin/accepted; health down, Redis DB 36, database mcritchie_studio_development_never_cache_deployer_token:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/never-cache-deployer-token (GitHub asked); no live build claim on never-cache-deployer-token; no review in progress; desk idle (born 37.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio never-cache-deployer-token --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/poison-release-suite-shell` | worktree | Hidden worktree; branch `feat/poison-release-suite-shell` is clean and HEAD e866c25a is contained in origin/accepted; health down, Redis DB 33, database mcritchie_studio_development_poison_release_suite_shell:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/poison-release-suite-shell (GitHub asked); no live build claim on poison-release-suite-shell; no review in progress; desk idle (born 58.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio poison-release-suite-shell --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/renew-loop-outlives-task` | worktree | Hidden worktree; branch `feat/renew-loop-outlives-task` is clean and HEAD fe40f37a is contained in origin/accepted; health down, Redis DB 61, database mcritchie_studio_development_renew_loop_outlives_task:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/renew-loop-outlives-task (GitHub asked); no live build claim on renew-loop-outlives-task; no review in progress; desk idle (born 11.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio renew-loop-outlives-task --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/repoint-ecosystem-build-vault` | worktree | Hidden worktree; branch `feat/repoint-ecosystem-build-vault` is clean and HEAD 7f65657f is contained in origin/accepted; health down, Redis DB 51, database mcritchie_studio_development_repoint_ecosystem_build_vault:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/repoint-ecosystem-build-vault (GitHub asked); no live build claim on repoint-ecosystem-build-vault; no review in progress; desk idle (born 26.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio repoint-ecosystem-build-vault --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/reviewer-select-seats-authors` | worktree | Hidden worktree; branch `feat/reviewer-select-seats-authors` is clean and HEAD 0f6c0ddf is contained in origin/accepted; health down, Redis DB 60, database mcritchie_studio_development_reviewer_select_seats_authors:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/reviewer-select-seats-authors (GitHub asked); no live build claim on reviewer-select-seats-authors; no review in progress; desk idle (born 11.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio reviewer-select-seats-authors --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/self-healing-token-sessions` | worktree | Hidden worktree; branch `feat/self-healing-token-sessions` is clean and HEAD 7cb6a0b3 is contained in origin/accepted; health down, Redis DB 46, database mcritchie_studio_development_self_healing_token_sessions:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/self-healing-token-sessions (GitHub asked); no live build claim on self-healing-token-sessions; no review in progress; desk idle (born 27.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio self-healing-token-sessions --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/tint-running-ladder-rungs` | worktree | Hidden worktree; branch `feat/tint-running-ladder-rungs` is clean and HEAD 9600dfc4 is contained in origin/accepted; health up, Redis DB 10, database mcritchie_studio_development_tint_running_ladder_rungs:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/tint-running-ladder-rungs (GitHub asked); no live build claim on tint-running-ladder-rungs; no review in progress; desk idle (born 57.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio tint-running-ladder-rungs --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/adopt-engine-age-attestation` | worktree | Hidden worktree; branch `feat/adopt-engine-age-attestation` is clean and HEAD 8795036 is contained in origin/accepted; health up, Redis DB 43, database turf_monster_development_adopt_engine_age_attestation:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/adopt-engine-age-attestation (GitHub asked); no live build claim on adopt-engine-age-attestation; no review in progress; desk idle (born 37.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster adopt-engine-age-attestation --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/adopt-engine-phantom-deeplink` | worktree | Hidden worktree; branch `feat/adopt-engine-phantom-deeplink` is clean and HEAD 1d2a743 is contained in origin/accepted; health up, Redis DB 50, database turf_monster_development_adopt_engine_phantom_deeplink:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/adopt-engine-phantom-deeplink (GitHub asked); no live build claim on adopt-engine-phantom-deeplink; no review in progress; desk idle (born 26.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster adopt-engine-phantom-deeplink --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/adopt-turf-engine-picker` | worktree | Hidden worktree; branch `feat/adopt-turf-engine-picker` is clean and HEAD f216cd7 is contained in origin/accepted; health up, Redis DB 45, database turf_monster_development_adopt_turf_engine_picker:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/adopt-turf-engine-picker (GitHub asked); no live build claim on adopt-turf-engine-picker; no review in progress; desk idle (born 36.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster adopt-turf-engine-picker --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/defork-turf-modal-host` | worktree | Hidden worktree; branch `feat/defork-turf-modal-host` is clean and HEAD c7caa1b is contained in origin/accepted; health up, Redis DB 32, database turf_monster_development_defork_turf_modal_host:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/defork-turf-modal-host (GitHub asked); no live build claim on defork-turf-modal-host; no review in progress; desk idle (born 58.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster defork-turf-modal-host --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/live-focus-game-ranking` | worktree | Hidden worktree; branch `feat/live-focus-game-ranking` is clean and HEAD 3b72183 is contained in origin/accepted; health up, Redis DB 56, database turf_monster_development_live_focus_game_ranking:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/live-focus-game-ranking (GitHub asked); no live build claim on live-focus-game-ranking; no review in progress; desk idle (born 26.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster live-focus-game-ranking --yes` during approved lifecycle cleanup. | removed 2026-08-30 |

<!-- agent-worktree remove 2026-08-30 -->
| `/Users/alex/projects/turf-monster/.worktrees/scroll-the-games-strip` | worktree | Hidden worktree; branch `feat/scroll-the-games-strip` is clean and HEAD 5fd2fb4 is contained in origin/accepted; health up, Redis DB 49, database turf_monster_development_scroll_the_games_strip:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/scroll-the-games-strip (GitHub asked); no live build claim on scroll-the-games-strip; no review in progress; desk idle (born 27.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster scroll-the-games-strip --yes` during approved lifecycle cleanup. | removed 2026-08-30 |
