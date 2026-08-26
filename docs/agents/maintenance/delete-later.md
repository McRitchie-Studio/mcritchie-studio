# Delete Later Ledger

This ledger tracks files and directories that look removable once replacement docs, merged PRs, or migration checks are complete. Do not delete from this list without confirming the condition.

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
| `/Users/alex/projects/turf-monster/.worktrees/turbo-concurrent-visit-rendering` | worktree | Hidden worktree; branch `feat/turbo-concurrent-visit-rendering` is clean and HEAD c9751ad is contained in origin/accepted; health up, Redis DB 23, database turf_monster_development_turbo_concurrent_visit_rendering:ok Removed against a hold — the desk was written to within the last 1.5h — somebody is working in it, and their uncommitted work is exactly what a teardown destroys. | Removed with `bin/agent-worktree remove turf-monster turbo-concurrent-visit-rendering --yes` during approved lifecycle cleanup. | removed 2026-08-24 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/blocked-tint-past-submitted` | worktree | Hidden worktree; branch `feat/blocked-tint-past-submitted` is clean and HEAD e0b5db81 is contained in origin/accepted; health up, Redis DB 37, database mcritchie_studio_development_blocked_tint_past_submitted:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/blocked-tint-past-submitted (GitHub asked); no live build claim on blocked-tint-past-submitted; no review in progress; desk idle (born 11.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio blocked-tint-past-submitted --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/certify-a-repo-without-rubocop` | worktree | Hidden worktree; branch `feat/certify-a-repo-without-rubocop` is clean and HEAD f99639be is contained in origin/accepted; health down, Redis DB 46, database mcritchie_studio_development_certify_a_repo_without_rubocop:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/certify-a-repo-without-rubocop (GitHub asked); no live build claim on certify-a-repo-without-rubocop; no review in progress; desk idle (born 10.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio certify-a-repo-without-rubocop --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/clear-the-quarantine-backlog` | worktree | Hidden worktree; branch `feat/clear-the-quarantine-backlog` is clean and HEAD 5990f56f is contained in origin/accepted; health down, Redis DB 16, database mcritchie_studio_development_clear_the_quarantine_backlog:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/clear-the-quarantine-backlog (GitHub asked); no live build claim on clear-the-quarantine-backlog; no review in progress; desk idle (born 95.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio clear-the-quarantine-backlog --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/drop-chain-ops-system-lane` | worktree | Hidden worktree; branch `feat/drop-chain-ops-system-lane` is clean and HEAD bcb716fd is contained in origin/accepted; health down, Redis DB 17, database mcritchie_studio_development_drop_chain_ops_system_lane:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/drop-chain-ops-system-lane (GitHub asked); no live build claim on drop-chain-ops-system-lane; no review in progress; desk idle (born 94.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio drop-chain-ops-system-lane --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fast-lane-auth-pointer` | worktree | Hidden worktree; branch `feat/fast-lane-auth-pointer` is clean and HEAD 18d533d3 is contained in origin/accepted; health down, Redis DB 36, database mcritchie_studio_development_fast_lane_auth_pointer:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fast-lane-auth-pointer (GitHub asked); no live build claim on fast-lane-auth-pointer; no review in progress; desk idle (born 11.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio fast-lane-auth-pointer --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-gem-ci-visibility` | worktree | Hidden worktree; branch `feat/fix-gem-ci-visibility` is clean and HEAD 21cfa81f is contained in origin/accepted; health down, Redis DB 41, database mcritchie_studio_development_fix_gem_ci_visibility:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-gem-ci-visibility (GitHub asked); no live build claim on fix-gem-ci-visibility; no review in progress; desk idle (born 10.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio fix-gem-ci-visibility --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-parallel-test-deadlock` | worktree | Hidden worktree; branch `feat/fix-parallel-test-deadlock` is clean and HEAD 0087f638 is contained in origin/accepted; health down, Redis DB 21, database mcritchie_studio_development_fix_parallel_test_deadlock:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-parallel-test-deadlock (GitHub asked); no bound task, so no build claim to hold it; desk idle (born 86.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio fix-parallel-test-deadlock --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/loosen-style-guide-heading-assertion` | worktree | Hidden worktree; branch `feat/loosen-style-guide-heading-assertion` is clean and HEAD 848417a2 is contained in origin/accepted; health down, Redis DB 34, database mcritchie_studio_development_loosen_style_guide_headin_8434cb28:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/loosen-style-guide-heading-assertion (GitHub asked); no live build claim on loosen-style-guide-heading-assertion; no review in progress; desk idle (born 11.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio loosen-style-guide-heading-assertion --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/show-local-test-progress` | worktree | Hidden worktree; branch `feat/show-local-test-progress` is clean and HEAD e37e2e22 is contained in origin/accepted; health up, Redis DB 18, database mcritchie_studio_development_show_local_test_progress:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/show-local-test-progress (GitHub asked); no live build claim on show-local-test-progress; no review in progress; desk idle (born 94.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio show-local-test-progress --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/source-control-operating-module` | worktree | Hidden worktree; branch `feat/source-control-operating-module` is clean and HEAD c7aca45b is contained in origin/accepted; health down, Redis DB 35, database mcritchie_studio_development_source_control_operating_module:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/source-control-operating-module (GitHub asked); no live build claim on source-control-operating-module; no review in progress; desk idle (born 11.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio source-control-operating-module --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/track-review-duration` | worktree | Hidden worktree; branch `feat/track-review-duration` is clean and HEAD 6a98274a is contained in origin/accepted; health up, Redis DB 45, database mcritchie_studio_development_track_review_duration:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/track-review-duration (GitHub asked); no live build claim on track-review-duration; no review in progress; desk idle (born 10.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio track-review-duration --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/adopt-engine-web3-step-up` | worktree | Hidden worktree; branch `feat/adopt-engine-web3-step-up` is clean and HEAD 991ae6c is contained in origin/accepted; health up, Redis DB 23, database turf_monster_development_adopt_engine_web3_step_up:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/adopt-engine-web3-step-up (GitHub asked); no live build claim on adopt-engine-web3-step-up; no review in progress; desk idle (born 33.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster adopt-engine-web3-step-up --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/brand-the-current-wallet` | worktree | Hidden worktree; branch `feat/brand-the-current-wallet` is clean and HEAD 458494f is contained in origin/accepted; health down, Redis DB 29, database turf_monster_development_brand_the_current_wallet:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/brand-the-current-wallet (GitHub asked); no live build claim on brand-the-current-wallet; no review in progress; desk idle (born 32.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster brand-the-current-wallet --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/consolidate-wallet-sign-in` | worktree | Hidden worktree; branch `feat/consolidate-wallet-sign-in` is clean and HEAD d285cd2 is contained in origin/accepted; health up, Redis DB 38, database turf_monster_development_consolidate_wallet_sign_in:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/consolidate-wallet-sign-in (GitHub asked); no live build claim on consolidate-wallet-sign-in; no review in progress; desk idle (born 11.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster consolidate-wallet-sign-in --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/document-badge-click-and-chip` | worktree | Hidden worktree; branch `feat/document-badge-click-and-chip` is clean and HEAD d961b46 is contained in origin/accepted; health down, Redis DB 13, database turf_monster_development_document_badge_click_and_chip:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/document-badge-click-and-chip (GitHub asked); no live build claim on document-badge-click-and-chip; no review in progress; desk idle (born 95.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster document-badge-click-and-chip --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/fix-parallel-test-deadlock` | worktree | Hidden worktree; branch `feat/fix-parallel-test-deadlock` is clean and HEAD 8c37610 is contained in origin/accepted; health down, Redis DB 19, database turf_monster_development_fix_parallel_test_deadlock:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-parallel-test-deadlock (GitHub asked); no live build claim on fix-parallel-test-deadlock; no review in progress; desk idle (born 86.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster fix-parallel-test-deadlock --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/fix-wallet-onboarding-return` | worktree | Hidden worktree; branch `feat/fix-wallet-onboarding-return` is clean and HEAD dee7d4e is contained in origin/accepted; health up, Redis DB 24, database turf_monster_development_fix_wallet_onboarding_return:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-wallet-onboarding-return (GitHub asked); no live build claim on fix-wallet-onboarding-return; no review in progress; desk idle (born 70.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster fix-wallet-onboarding-return --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/graceful-wallet-session-switch` | worktree | Hidden worktree; branch `feat/graceful-wallet-session-switch` is clean and HEAD 70dad23 is contained in origin/accepted; health up, Redis DB 25, database turf_monster_development_graceful_wallet_session_switch:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/graceful-wallet-session-switch (GitHub asked); no live build claim on graceful-wallet-session-switch; no review in progress; desk idle (born 70.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster graceful-wallet-session-switch --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/harden-solana-health-reporting` | worktree | Hidden worktree; branch `feat/harden-solana-health-reporting` is clean and HEAD 8fcece9 is contained in origin/accepted; health down, Redis DB 50, database turf_monster_development_harden_solana_health_reporting:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/harden-solana-health-reporting (GitHub asked); no live build claim on harden-solana-health-reporting; no review in progress; desk idle (born 102.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster harden-solana-health-reporting --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/hold-for-free-entry` | worktree | Hidden worktree; branch `feat/hold-for-free-entry` is clean and HEAD 173f1f2 is contained in origin/accepted; health port-busy, Redis DB 22, database turf_monster_development_hold_for_free_entry:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/hold-for-free-entry (GitHub asked); no live build claim on hold-for-free-entry; no review in progress; desk idle (born 124.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster hold-for-free-entry --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/make-reduced-motion-reach-specs` | worktree | Hidden worktree; branch `feat/make-reduced-motion-reach-specs` is clean and HEAD 1010e9b is contained in origin/accepted; health down, Redis DB 51, database turf_monster_development_make_reduced_motion_reach_specs:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/make-reduced-motion-reach-specs (GitHub asked); no live build claim on make-reduced-motion-reach-specs; no review in progress; desk idle (born 102.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster make-reduced-motion-reach-specs --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/restart-phantom-debug-retry` | worktree | Hidden worktree; branch `feat/restart-phantom-debug-retry` is clean and HEAD 0b5e7f5 is contained in origin/accepted; health up, Redis DB 55, database turf_monster_development_restart_phantom_debug_retry:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/restart-phantom-debug-retry (GitHub asked); no live build claim on restart-phantom-debug-retry; no review in progress; desk idle (born 6.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster restart-phantom-debug-retry --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/route-solana-clients-through-config` | worktree | Hidden worktree; branch `feat/route-solana-clients-through-config` is clean and HEAD 5404c2c is contained in origin/accepted; health down, Redis DB 53, database turf_monster_development_route_solana_clients_through_config:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/route-solana-clients-through-config (GitHub asked); no live build claim on route-solana-clients-through-config; no review in progress; desk idle (born 102.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster route-solana-clients-through-config --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/tighten-solana-rpc-comments` | worktree | Hidden worktree; branch `feat/tighten-solana-rpc-comments` is clean and HEAD 2e51e2b is contained in origin/accepted; health down, Redis DB 54, database turf_monster_development_tighten_solana_rpc_comments:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/tighten-solana-rpc-comments (GitHub asked); no live build claim on tighten-solana-rpc-comments; no review in progress; desk idle (born 102.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster tighten-solana-rpc-comments --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/turbo-restore-under-reduced-motion` | worktree | Hidden worktree; branch `feat/turbo-restore-under-reduced-motion` is clean and HEAD 62277df is contained in origin/accepted; health down, Redis DB 10, database turf_monster_development_turbo_restore_under_reduced_motion:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/turbo-restore-under-reduced-motion (GitHub asked); no live build claim on turbo-restore-under-reduced-motion; no review in progress; desk idle (born 96.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster turbo-restore-under-reduced-motion --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/wallet-signup-walks-onboarding` | worktree | Hidden worktree; branch `feat/wallet-signup-walks-onboarding` is clean and HEAD 9014f04 is contained in origin/accepted; health up, Redis DB 12, database turf_monster_development_wallet_signup_walks_onboarding:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/wallet-signup-walks-onboarding (GitHub asked); no live build claim on wallet-signup-walks-onboarding; no review in progress; desk idle (born 96.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster wallet-signup-walks-onboarding --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/web3-step-up-auth` | worktree | Hidden worktree; branch `feat/web3-step-up-auth` is clean and HEAD 975462a is contained in origin/accepted; health up, Redis DB 43, database turf_monster_development_web3_step_up_auth:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/web3-step-up-auth (GitHub asked); no live build claim on web3-step-up-auth; no review in progress; desk idle (born 104.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster web3-step-up-auth --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/chain-ops/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD 749b38c is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 95.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove chain-ops _ship --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/chain-ops/.worktrees/drop-chain-ops-system-lane` | worktree | Hidden worktree; branch `feat/drop-chain-ops-system-lane` is clean and HEAD 629e72e is contained in origin/accepted; health down, Redis DB 32, database chain_ops_development_drop_chain_ops_system_lane:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/drop-chain-ops-system-lane (GitHub asked); no live build claim on drop-chain-ops-system-lane; no review in progress; desk idle (born 118.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove chain-ops drop-chain-ops-system-lane --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD 3f7e7c58 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 86.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio _ship --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/certify-without-a-lint-lane` | worktree | Hidden worktree; branch `feat/certify-without-a-lint-lane` is clean and HEAD b4f8fce8 is contained in origin/accepted; health down, Redis DB 49, database mcritchie_studio_development_certify_without_a_lint_lane:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/certify-without-a-lint-lane (GitHub asked); no live build claim on certify-without-a-lint-lane; no review in progress; desk idle (born 9.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio certify-without-a-lint-lane --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/draw-ladder-position-track` | worktree | Hidden worktree; branch `feat/draw-ladder-position-track` is clean and HEAD 7789f65f is contained in origin/accepted; health up, Redis DB 56, database mcritchie_studio_development_draw_ladder_position_track:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/draw-ladder-position-track (GitHub asked); no live build claim on draw-ladder-position-track; no review in progress; desk idle (born 6.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio draw-ladder-position-track --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD 13800ea is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 112.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster _ship --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/adopt-engine-solana-blocks` | worktree | Hidden worktree; branch `feat/adopt-engine-solana-blocks` is clean and HEAD 1d09fea is contained in origin/accepted; health up, Redis DB 57, database turf_monster_development_adopt_engine_solana_blocks:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/adopt-engine-solana-blocks (GitHub asked); no live build claim on adopt-engine-solana-blocks; no review in progress; desk idle (born 6.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster adopt-engine-solana-blocks --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/auto-mint-level-up-tokens` | worktree | Hidden worktree; branch `feat/auto-mint-level-up-tokens` is clean and HEAD 1bd7db5 is contained in origin/accepted; health up, Redis DB 15, database turf_monster_development_auto_mint_level_up_tokens:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/auto-mint-level-up-tokens (GitHub asked); no live build claim on auto-mint-level-up-tokens; no review in progress; desk idle (born 95.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster auto-mint-level-up-tokens --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- agent-worktree remove 2026-08-25 -->
| `/Users/alex/projects/turf-monster/.worktrees/patch-phantom-across-adapters` | worktree | Hidden worktree; branch `feat/patch-phantom-across-adapters` is clean and HEAD 843dc7e is contained in origin/accepted; health down, Redis DB 60, database turf_monster_development_patch_phantom_across_adapters:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/patch-phantom-across-adapters (GitHub asked); no live build claim on patch-phantom-across-adapters; no review in progress; desk idle (born 2.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster patch-phantom-across-adapters --yes` during approved lifecycle cleanup. | removed 2026-08-25 |

<!-- clean-up Phase 4 findings 2026-08-25 — HELD, not deleted -->
| `postgres: 498 × *_development_* databases` | database | Per-worktree Postgres databases whose desk is long gone. Measured 2026-08-25: 512 per-worktree databases exist, only 14 are owned by a live desk; the other **498 total ~11.7 GB** (cluster total 41 GB). `bin/agent-worktree remove` flushes the desk's Redis DB but never drops its Postgres database, so every teardown since the beginning has left one behind. 84 of the 498 are Rails parallel-test shards (`<db>-0` … `<db>-13`). Detection was validated: no live desk's database is in the orphan set, and the two databases with live connections at measurement time (`turf_monster_development_adopt_birthday_age_gate_flow`, `mcritchie_studio_development_pin_applications_ladder_row`) were correctly spared. | NOT dropped this run, deliberately: the disk is at 32% (614 GB free of 926 GB), so ~11.7 GB is no pressure, and 498 irreversible drops is far beyond routine residue with four sessions live. Drop only with an explicit operator go-ahead AND a `pg_stat_activity` guard per database — one apparent orphan (`mcritchie_studio_development_route_last_release_animations`) showed a transient live connection during measurement. The durable fix belongs upstream in `bin/agent-worktree remove`, so a one-time sweep does not just reset a counter that climbs again. | held — needs decision |
| `/Users/alex/projects/mcritchie-studio-ai-builder-cache` | worktree | Untracked git worktree OUTSIDE any `.worktrees/` tree, flagged by `bin/agent-worktree doctor` as `orphan:…dbf07763` — not in the managed registry, so no sweep will ever reach it. Branch `feat/ai-builder-cache-run` @ c7d5d326, tree clean, created 2026-06-17. Holds **no Redis DB**, so removing it frees no band capacity. Carries **5 commits / 517 insertions across 27 files** that are not on `origin/accepted` (admin gating for builder roster controls, builder cache run keys, sticky-table fixes, 110 new lines of `builders_controller_test.rb`). No board task exists (`ai-builder-cache-run` → 404). | Code is SAFE: `origin/feat/ai-builder-cache-run` is at the identical SHA c7d5d326, zero unpushed — origin holds it, so removal loses nothing. Held anyway because it is an unresolved **orphaned-fix** question, not a capacity question: per the clean-up SOP, a branch is superseded only if you can point at the code that supersedes it, and that check has not been done for these 5 commits. Do that check, record the verdict in `parking-lot.md`, then remove. | held — needs decision |
