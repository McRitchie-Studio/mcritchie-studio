# Delete Later Ledger

This ledger tracks files and directories that look removable once replacement docs, merged PRs, or migration checks are complete. Do not delete from this list without confirming the condition.

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
| `/Users/alex/projects/mcritchie-studio/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD be798149 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 8.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio _ship --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

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
| `/Users/alex/projects/mcritchie-studio/.worktrees/shrink-agent-portrait-assets` | worktree | Hidden worktree; branch `feat/shrink-agent-portrait-assets` is clean and HEAD 15a947f9 is contained in origin/accepted; health up, Redis DB 10, database mcritchie_studio_development_shrink_agent_portrait_assets:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/shrink-agent-portrait-assets (GitHub asked); no bound task, so no build claim to hold it; desk idle (born 9.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio shrink-agent-portrait-assets --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD ddfad29 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 8.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster _ship --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

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
| `/Users/alex/projects/mcritchie-studio/.worktrees/quiet-and-align-ladder-cards` | worktree | Hidden worktree; branch `feat/quiet-and-align-ladder-cards` is clean and HEAD 22e95617 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for feat/quiet-and-align-ladder-cards (GitHub asked); no bound task, so no build claim to hold it; desk idle (born 11.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio quiet-and-align-ladder-cards --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/stand-up-onchain-engine` | worktree | Hidden worktree; branch `feat/stand-up-onchain-engine` is clean and HEAD 0486aee6 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for feat/stand-up-onchain-engine (GitHub asked); no bound task, so no build claim to hold it; desk idle (born 12.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio stand-up-onchain-engine --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/sweep-discovered-repos-safely` | worktree | Hidden worktree; branch `feat/sweep-discovered-repos-safely` is clean and HEAD fd8dab39 is contained in origin/accepted; health down, Redis DB 17, database mcritchie_studio_development_sweep_discovered_repos_safely:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/sweep-discovered-repos-safely (GitHub asked); no live build claim on sweep-discovered-repos-safely; no review in progress; desk idle (born 9.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio sweep-discovered-repos-safely --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/studio-engine/.worktrees/centralize-geo-into-engine` | worktree | Hidden worktree; branch `feat/centralize-geo-into-engine` is clean and HEAD c5358bf is contained in origin/accepted; health missing-env, Redis DB , database unknown Removed against a hold — a discovered repo's desk can never carry a bound task (bind-task routes through the registry), so the build, review and PR channels can never answer for it — and desk mtimes alone cannot prove a gem desk abandoned, because a cert writes nothing into its desk for longer than the idle window. Withholding rather than nominating a desk we cannot verify; tear it down deliberately with bin/agent-worktree remove studio-engine centralize-geo-into-engine --yes. | Removed with `bin/agent-worktree remove studio-engine centralize-geo-into-engine --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/studio-engine/.worktrees/refresh-engine-readme-release` | worktree | Hidden worktree; branch `feat/refresh-engine-readme-release` is clean and HEAD 45f66c9 is contained in origin/accepted; health missing-env, Redis DB , database unknown Removed against a hold — a discovered repo's desk can never carry a bound task (bind-task routes through the registry), so the build, review and PR channels can never answer for it — and desk mtimes alone cannot prove a gem desk abandoned, because a cert writes nothing into its desk for longer than the idle window. Withholding rather than nominating a desk we cannot verify; tear it down deliberately with bin/agent-worktree remove studio-engine refresh-engine-readme-release --yes. | Removed with `bin/agent-worktree remove studio-engine refresh-engine-readme-release --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/studio-engine/.worktrees/vendor-the-montserrat-webfont` | worktree | Hidden worktree; branch `feat/vendor-the-montserrat-webfont` is clean and HEAD b213dc8 is contained in origin/accepted; health missing-env, Redis DB , database unknown Removed against a hold — a discovered repo's desk can never carry a bound task (bind-task routes through the registry), so the build, review and PR channels can never answer for it — and desk mtimes alone cannot prove a gem desk abandoned, because a cert writes nothing into its desk for longer than the idle window. Withholding rather than nominating a desk we cannot verify; tear it down deliberately with bin/agent-worktree remove studio-engine vendor-the-montserrat-webfont --yes. | Removed with `bin/agent-worktree remove studio-engine vendor-the-montserrat-webfont --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/commit-worktree-removal-ledger` | worktree | Hidden worktree; branch `feat/commit-worktree-removal-ledger` is clean and HEAD 4714a271 is contained in origin/accepted; health down, Redis DB 19, database mcritchie_studio_development_commit_worktree_removal_ledger:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/commit-worktree-removal-ledger (GitHub asked); no live build claim on commit-worktree-removal-ledger; no review in progress; desk idle (born 14.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio commit-worktree-removal-ledger --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/sweeper-covers-every-desk` | worktree | Hidden worktree; branch `feat/sweeper-covers-every-desk` is clean and HEAD 80e32791 is contained in origin/accepted; health down, Redis DB 15, database mcritchie_studio_development_sweeper_covers_every_desk:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/sweeper-covers-every-desk (GitHub asked); no live build claim on sweeper-covers-every-desk; no review in progress; desk idle (born 44.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio sweeper-covers-every-desk --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/turf-monster/.worktrees/document-wallet-probe-seam` | worktree | Hidden worktree; branch `feat/document-wallet-probe-seam` is clean and HEAD 0412025 is contained in origin/accepted; health down, Redis DB 16, database turf_monster_development_document_wallet_probe_seam:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/document-wallet-probe-seam (GitHub asked); no live build claim on document-wallet-probe-seam; no review in progress; desk idle (born 14.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster document-wallet-probe-seam --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/turf-monster/.worktrees/enable-faucet-on-qa` | worktree | Hidden worktree; branch `feat/enable-faucet-on-qa` is clean and HEAD 42d73d0 is contained in origin/accepted; health down, Redis DB 41, database turf_monster_development_enable_faucet_on_qa:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/enable-faucet-on-qa (GitHub asked); no live build claim on enable-faucet-on-qa; no review in progress; desk idle (born 17.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster enable-faucet-on-qa --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/turf-monster/.worktrees/require-solana-network-in-production` | worktree | Hidden worktree; branch `feat/require-solana-network-in-production` is clean and HEAD 643c2df is contained in origin/accepted; health down, Redis DB 18, database turf_monster_development_require_solana_network_in_production:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/require-solana-network-in-production (GitHub asked); no live build claim on require-solana-network-in-production; no review in progress; desk idle (born 14.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster require-solana-network-in-production --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/turf-monster/.worktrees/run-the-gated-payment-specs` | worktree | Hidden worktree; branch `feat/run-the-gated-payment-specs` is clean and HEAD e0dd72f is contained in origin/accepted; health down, Redis DB 21, database turf_monster_development_run_the_gated_payment_specs:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/run-the-gated-payment-specs (GitHub asked); no live build claim on run-the-gated-payment-specs; no review in progress; desk idle (born 14.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster run-the-gated-payment-specs --yes` during approved lifecycle cleanup. | removed 2026-08-21 |

<!-- agent-worktree remove 2026-08-21 -->
| `/Users/alex/projects/turf-monster/.worktrees/sparkle-free-entry-badge` | worktree | Hidden worktree; branch `feat/sparkle-free-entry-badge` is clean and HEAD 0416073 is contained in origin/accepted; health up, Redis DB 12, database turf_monster_development_sparkle_free_entry_badge:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/sparkle-free-entry-badge (GitHub asked); no live build claim on sparkle-free-entry-badge; no review in progress; desk idle (born 14.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster sparkle-free-entry-badge --yes` during approved lifecycle cleanup. | removed 2026-08-21 |
