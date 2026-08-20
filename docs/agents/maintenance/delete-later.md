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
| `/Users/alex/projects/mcritchie-industries/.worktrees/bound-industries-ci-hangs` | worktree | Hidden worktree; branch `feat/bound-industries-ci-hangs` is clean and HEAD 03b5476 is contained in origin/accepted; health down, Redis DB 41, database mcritchie_industries_development_bound_industries_ci_hangs:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/bound-industries-ci-hangs (GitHub asked); no live build claim on bound-industries-ci-hangs; no review in progress; desk idle (born 14.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-industries bound-industries-ci-hangs --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/groom-slowest-test-files` | worktree | Hidden worktree; branch `feat/groom-slowest-test-files` is clean and HEAD e278721a is contained in origin/accepted; health down, Redis DB 45, database mcritchie_studio_development_groom_slowest_test_files:missing Cleared: merged into origin/accepted, tree clean; no open PR recorded for feat/groom-slowest-test-files (GitHub unreachable; the bound task shows nothing unlanded); no live build claim on groom-slowest-test-files; no review in progress; desk idle (born 14.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio groom-slowest-test-files --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/typing-first-name-placeholder` | worktree | Hidden worktree; branch `feat/typing-first-name-placeholder` is clean and HEAD 1fd9fa8 is contained in origin/accepted; health up, Redis DB 49, database turf_monster_development_typing_first_name_placeholder:ok Cleared: merged into origin/accepted, tree clean; no open PR recorded for feat/typing-first-name-placeholder (GitHub unreachable; the bound task shows nothing unlanded); no live build claim on typing-first-name-placeholder; no review in progress; desk idle (born 40.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster typing-first-name-placeholder --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD d7ccca8d is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 19.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio _ship --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/app-ladder-status-row` | worktree | Hidden worktree; branch `feat/app-ladder-status-row` is clean and HEAD b094baac is contained in origin/accepted; health up, Redis DB 12, database mcritchie_studio_development_app_ladder_status_row:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/app-ladder-status-row (GitHub asked); no live build claim on app-ladder-status-row; no review in progress; desk idle (born 32.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio app-ladder-status-row --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/attribute-orphan-commits-by-slug` | worktree | Hidden worktree; branch `feat/attribute-orphan-commits-by-slug` is clean and HEAD d2753c1b is contained in origin/accepted; health down, Redis DB 55, database mcritchie_studio_development_attribute_orphan_commits_by_slug:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/attribute-orphan-commits-by-slug (GitHub asked); no live build claim on attribute-orphan-commits-by-slug; no review in progress; desk idle (born 42.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio attribute-orphan-commits-by-slug --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/bound-and-retry-apt-fetches` | worktree | Hidden worktree; branch `feat/bound-and-retry-apt-fetches` is clean and HEAD 31e80b93 is contained in origin/accepted; health down, Redis DB 21, database mcritchie_studio_development_bound_and_retry_apt_fetches:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/bound-and-retry-apt-fetches (GitHub asked); no live build claim on bound-and-retry-apt-fetches; no review in progress; desk idle (born 24.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio bound-and-retry-apt-fetches --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/broadcast-block-to-board` | worktree | Hidden worktree; branch `feat/broadcast-block-to-board` is clean and HEAD 5b4b15eb is contained in origin/accepted; health down, Redis DB 24, database mcritchie_studio_development_broadcast_block_to_board:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/broadcast-block-to-board (GitHub asked); no live build claim on broadcast-block-to-board; no review in progress; desk idle (born 19.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio broadcast-block-to-board --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/cache-deployment-stage-averages` | worktree | Hidden worktree; branch `feat/cache-deployment-stage-averages` is clean and HEAD d59ef567 is contained in origin/accepted; health down, Redis DB 35, database mcritchie_studio_development_cache_deployment_stage_averages:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/cache-deployment-stage-averages (GitHub asked); no live build claim on cache-deployment-stage-averages; no review in progress; desk idle (born 18.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio cache-deployment-stage-averages --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/cert-gate-loses-multi-repo` | worktree | Hidden worktree; branch `feat/cert-gate-loses-multi-repo` is clean and HEAD 8842cd92 is contained in origin/accepted; health down, Redis DB 54, database mcritchie_studio_development_cert_gate_loses_multi_repo:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/cert-gate-loses-multi-repo (GitHub asked); no live build claim on cert-gate-loses-multi-repo; no review in progress; desk idle (born 42.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio cert-gate-loses-multi-repo --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/certify-accepted-everywhere` | worktree | Hidden worktree; branch `feat/certify-accepted-everywhere` is clean and HEAD 7142cfd6 is contained in origin/accepted; health down, Redis DB 59, database mcritchie_studio_development_certify_accepted_everywhere:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/certify-accepted-everywhere (GitHub asked); no live build claim on certify-accepted-everywhere; no review in progress; desk idle (born 42.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio certify-accepted-everywhere --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/certify-engine-before-publish` | worktree | Hidden worktree; branch `feat/certify-engine-before-publish` is clean and HEAD 368ad211 is contained in origin/accepted; health down, Redis DB 25, database mcritchie_studio_development_certify_engine_before_publish:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/certify-engine-before-publish (GitHub asked); no live build claim on certify-engine-before-publish; no review in progress; desk idle (born 48.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio certify-engine-before-publish --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/close-board-filter-flake` | worktree | Hidden worktree; branch `feat/close-board-filter-flake` is clean and HEAD 34e34d7d is contained in origin/accepted; health down, Redis DB 46, database mcritchie_studio_development_close_board_filter_flake:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/close-board-filter-flake (GitHub asked); no live build claim on close-board-filter-flake; no review in progress; desk idle (born 42.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio close-board-filter-flake --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/compress-and-shrink-payload` | worktree | Hidden worktree; branch `feat/compress-and-shrink-payload` is clean and HEAD 336f4a71 is contained in origin/accepted; health down, Redis DB 33, database mcritchie_studio_development_compress_and_shrink_payload:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/compress-and-shrink-payload (GitHub asked); no live build claim on compress-and-shrink-payload; no review in progress; desk idle (born 18.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio compress-and-shrink-payload --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/document-parallel-workers-clamp` | worktree | Hidden worktree; branch `feat/document-parallel-workers-clamp` is clean and HEAD 2b89fe3f is contained in origin/accepted; health down, Redis DB 16, database mcritchie_studio_development_document_parallel_workers_clamp:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/document-parallel-workers-clamp (GitHub asked); no live build claim on document-parallel-workers-clamp; no review in progress; desk idle (born 29.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio document-parallel-workers-clamp --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/document-the-settled-click-guard` | worktree | Hidden worktree; branch `feat/document-the-settled-click-guard` is clean and HEAD e09d2458 is contained in origin/accepted; health down, Redis DB 63, database mcritchie_studio_development_document_the_settled_click_guard:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/document-the-settled-click-guard (GitHub asked); no live build claim on document-the-settled-click-guard; no review in progress; desk idle (born 41.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio document-the-settled-click-guard --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/drop-ladder-stale-state` | worktree | Hidden worktree; branch `feat/drop-ladder-stale-state` is clean and HEAD 648a3df7 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for feat/drop-ladder-stale-state (GitHub asked); no bound task, so no build claim to hold it; desk idle (born 3.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio drop-ladder-stale-state --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-board-chip-flake` | worktree | Hidden worktree; branch `feat/fix-board-chip-flake` is clean and HEAD 7e1cd1e6 is contained in origin/accepted; health down, Redis DB 22, database mcritchie_studio_development_fix_board_chip_flake:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-board-chip-flake (GitHub asked); no live build claim on fix-board-chip-flake; no review in progress; desk idle (born 23.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio fix-board-chip-flake --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-board-filter-settling-flake` | worktree | Hidden worktree; branch `feat/fix-board-filter-settling-flake` is clean and HEAD 6ccf7cc0 is contained in origin/accepted; health down, Redis DB 23, database mcritchie_studio_development_fix_board_filter_settling_flake:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-board-filter-settling-flake (GitHub asked); no live build claim on fix-board-filter-settling-flake; no review in progress; desk idle (born 21.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio fix-board-filter-settling-flake --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-crew-avatar-queries` | worktree | Hidden worktree; branch `feat/fix-crew-avatar-queries` is clean and HEAD 5296ea90 is contained in origin/accepted; health down, Redis DB 34, database mcritchie_studio_development_fix_crew_avatar_queries:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-crew-avatar-queries (GitHub asked); no live build claim on fix-crew-avatar-queries; no review in progress; desk idle (born 18.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio fix-crew-avatar-queries --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-repo-root-tmpdir-race` | worktree | Hidden worktree; branch `feat/fix-repo-root-tmpdir-race` is clean and HEAD 21df171e is contained in origin/accepted; health down, Redis DB 51, database mcritchie_studio_development_fix_repo_root_tmpdir_race:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-repo-root-tmpdir-race (GitHub asked); no live build claim on fix-repo-root-tmpdir-race; no review in progress; desk idle (born 7.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio fix-repo-root-tmpdir-race --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/install-engine-migrations-in-sweep` | worktree | Hidden worktree; branch `feat/install-engine-migrations-in-sweep` is clean and HEAD 2336a9ae is contained in origin/accepted; health down, Redis DB 18, database mcritchie_studio_development_install_engine_migrations_in_sweep:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/install-engine-migrations-in-sweep (GitHub asked); no live build claim on install-engine-migrations-in-sweep; no review in progress; desk idle (born 24.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio install-engine-migrations-in-sweep --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/ratchet-the-rails-skip-ceiling` | worktree | Hidden worktree; branch `feat/ratchet-the-rails-skip-ceiling` is clean and HEAD 4eed233a is contained in origin/accepted; health down, Redis DB 56, database mcritchie_studio_development_ratchet_the_rails_skip_ceiling:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/ratchet-the-rails-skip-ceiling (GitHub asked); no live build claim on ratchet-the-rails-skip-ceiling; no review in progress; desk idle (born 6.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio ratchet-the-rails-skip-ceiling --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/repair-remaining-quarantined-specs` | worktree | Hidden worktree; branch `feat/repair-remaining-quarantined-specs` is clean and HEAD eb70db89 is contained in origin/accepted; health down, Redis DB 19, database mcritchie_studio_development_repair_remaining_quarantined_specs:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/repair-remaining-quarantined-specs (GitHub asked); no live build claim on repair-remaining-quarantined-specs; no review in progress; desk idle (born 24.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio repair-remaining-quarantined-specs --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/review-gate-reads-one-repo` | worktree | Hidden worktree; branch `feat/review-gate-reads-one-repo` is clean and HEAD ac421633 is contained in origin/accepted; health down, Redis DB 13, database mcritchie_studio_development_review_gate_reads_one_repo:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/review-gate-reads-one-repo (GitHub asked); no live build claim on review-gate-reads-one-repo; no review in progress; desk idle (born 32.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio review-gate-reads-one-repo --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/scope-board-to-live-tasks` | worktree | Hidden worktree; branch `feat/scope-board-to-live-tasks` is clean and HEAD 4271b6b9 is contained in origin/accepted; health down, Redis DB 32, database mcritchie_studio_development_scope_board_to_live_tasks:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/scope-board-to-live-tasks (GitHub asked); no live build claim on scope-board-to-live-tasks; no review in progress; desk idle (born 19.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio scope-board-to-live-tasks --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/shard-the-rails-suite` | worktree | Hidden worktree; branch `feat/shard-the-rails-suite` is clean and HEAD f8773213 is contained in origin/accepted; health down, Redis DB 36, database mcritchie_studio_development_shard_the_rails_suite:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/shard-the-rails-suite (GitHub asked); no live build claim on shard-the-rails-suite; no review in progress; desk idle (born 17.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio shard-the-rails-suite --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/shrink-agent-portrait-assets` | worktree | Hidden worktree; branch `feat/shrink-agent-portrait-assets` is clean and HEAD d4077fb0 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for feat/shrink-agent-portrait-assets (GitHub asked); no bound task, so no build claim to hold it; desk idle (born 2.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio shrink-agent-portrait-assets --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/trim-ci-setup-floor` | worktree | Hidden worktree; branch `feat/trim-ci-setup-floor` is clean and HEAD b1bac60b is contained in origin/accepted; health down, Redis DB 48, database mcritchie_studio_development_trim_ci_setup_floor:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/trim-ci-setup-floor (GitHub asked); no live build claim on trim-ci-setup-floor; no review in progress; desk idle (born 15.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio trim-ci-setup-floor --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/vendor-font-in-lineup-graphic` | worktree | Hidden worktree; branch `feat/vendor-font-in-lineup-graphic` is clean and HEAD 8d8371c1 is contained in origin/accepted; health up, Redis DB 43, database mcritchie_studio_development_vendor_font_in_lineup_graphic:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/vendor-font-in-lineup-graphic (GitHub asked); no live build claim on vendor-font-in-lineup-graphic; no review in progress; desk idle (born 16.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio vendor-font-in-lineup-graphic --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD 1ada513 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 19.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster _ship --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/adopt-engine-geo-primitives` | worktree | Hidden worktree; branch `feat/adopt-engine-geo-primitives` is clean and HEAD 86bd452 is contained in origin/accepted; health port-busy, Redis DB 10, database turf_monster_development_adopt_engine_geo_primitives:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/adopt-engine-geo-primitives (GitHub asked); no live build claim on adopt-engine-geo-primitives; no review in progress; desk idle (born 40.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster adopt-engine-geo-primitives --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/bound-turf-apt-fetches` | worktree | Hidden worktree; branch `feat/bound-turf-apt-fetches` is clean and HEAD c80eaf2 is contained in origin/accepted; health down, Redis DB 38, database turf_monster_development_bound_turf_apt_fetches:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/bound-turf-apt-fetches (GitHub asked); no live build claim on bound-turf-apt-fetches; no review in progress; desk idle (born 17.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster bound-turf-apt-fetches --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/certify-accepted-everywhere` | worktree | Hidden worktree; branch `feat/certify-accepted-everywhere` is clean and HEAD 4440cfd is contained in origin/accepted; health down, Redis DB 60, database turf_monster_development_certify_accepted_everywhere:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/certify-accepted-everywhere (GitHub asked); no live build claim on certify-accepted-everywhere; no review in progress; desk idle (born 42.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster certify-accepted-everywhere --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/consolidate-turf-static-lane` | worktree | Hidden worktree; branch `feat/consolidate-turf-static-lane` is clean and HEAD 03712ae is contained in origin/accepted; health down, Redis DB 57, database turf_monster_development_consolidate_turf_static_lane:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/consolidate-turf-static-lane (GitHub asked); no live build claim on consolidate-turf-static-lane; no review in progress; desk idle (born 6.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster consolidate-turf-static-lane --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/correct-turbo-cache-doc` | worktree | Hidden worktree; branch `feat/correct-turbo-cache-doc` is clean and HEAD 64544ca is contained in origin/accepted; health down, Redis DB 17, database turf_monster_development_correct_turbo_cache_doc:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/correct-turbo-cache-doc (GitHub asked); no live build claim on correct-turbo-cache-doc; no review in progress; desk idle (born 27.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster correct-turbo-cache-doc --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/drop-turf-empty-system-lane` | worktree | Hidden worktree; branch `feat/drop-turf-empty-system-lane` is clean and HEAD 1f77860 is contained in origin/accepted; health down, Redis DB 37, database turf_monster_development_drop_turf_empty_system_lane:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/drop-turf-empty-system-lane (GitHub asked); no live build claim on drop-turf-empty-system-lane; no review in progress; desk idle (born 17.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster drop-turf-empty-system-lane --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/fix-turf-navbar-overflow` | worktree | Hidden worktree; branch `feat/fix-turf-navbar-overflow` is clean and HEAD fc9e718 is contained in origin/accepted; health up, Redis DB 29, database turf_monster_development_fix_turf_navbar_overflow:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-turf-navbar-overflow (GitHub asked); no live build claim on fix-turf-navbar-overflow; no review in progress; desk idle (born 19.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster fix-turf-navbar-overflow --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/give-turf-an-executed-set` | worktree | Hidden worktree; branch `feat/give-turf-an-executed-set` is clean and HEAD 8fe7992 is contained in origin/accepted; health down, Redis DB 50, database turf_monster_development_give_turf_an_executed_set:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/give-turf-an-executed-set (GitHub asked); no live build claim on give-turf-an-executed-set; no review in progress; desk idle (born 14.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster give-turf-an-executed-set --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/turf-monster/.worktrees/wallet-setup-modal-upgrade` | worktree | Hidden worktree; branch `feat/wallet-setup-modal-upgrade` is clean and HEAD d769e02 is contained in origin/accepted; health up, Redis DB 53, database turf_monster_development_wallet_setup_modal_upgrade:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/wallet-setup-modal-upgrade (GitHub asked); no live build claim on wallet-setup-modal-upgrade; no review in progress; desk idle (born 42.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster wallet-setup-modal-upgrade --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD 49c23f5 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 9.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-industries _ship --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/certify-accepted-everywhere` | worktree | Hidden worktree; branch `feat/certify-accepted-everywhere` is clean and HEAD 461af09 is contained in origin/accepted; health down, Redis DB 61, database mcritchie_industries_development_certify_accepted_everywhere:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/certify-accepted-everywhere (GitHub asked); no live build claim on certify-accepted-everywhere; no review in progress; desk idle (born 42.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-industries certify-accepted-everywhere --yes` during approved lifecycle cleanup. | removed 2026-08-20 |

<!-- agent-worktree remove 2026-08-20 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/consolidate-industries-static-lane` | worktree | Hidden worktree; branch `feat/consolidate-industries-static-lane` is clean and HEAD cbc1e40 is contained in origin/accepted; health down, Redis DB 58, database mcritchie_industries_development_consolidate_industrie_111b6f9a:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/consolidate-industries-static-lane (GitHub asked); no live build claim on consolidate-industries-static-lane; no review in progress; desk idle (born 6.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-industries consolidate-industries-static-lane --yes` during approved lifecycle cleanup. | removed 2026-08-20 |
