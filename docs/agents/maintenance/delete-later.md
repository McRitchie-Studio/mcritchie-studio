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
| `/Users/alex/projects/mcritchie-studio/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD c46790dc is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 128.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio _ship --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/ask-new-users-name` | worktree | Hidden worktree; branch `feat/ask-new-users-name` is clean and HEAD ff695462 is contained in origin/accepted; health down, Redis DB 12, database mcritchie_studio_development_ask_new_users_name:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/ask-new-users-name (GitHub asked); no live build claim on ask-new-users-name; no review in progress; desk idle (born 114.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio ask-new-users-name --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/await-gem-before-lock-bump` | worktree | Hidden worktree; branch `feat/await-gem-before-lock-bump` is clean and HEAD e2141a71 is contained in origin/accepted; health down, Redis DB 41, database mcritchie_studio_development_await_gem_before_lock_bump:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/await-gem-before-lock-bump (GitHub asked); no live build claim on await-gem-before-lock-bump; no review in progress; desk idle (born 75.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio await-gem-before-lock-bump --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/await-versions-not-info` | worktree | Hidden worktree; branch `feat/await-versions-not-info` is clean and HEAD 4a95e79a is contained in origin/accepted; health down, Redis DB 60, database mcritchie_studio_development_await_versions_not_info:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/await-versions-not-info (GitHub asked); no live build claim on await-versions-not-info; no review in progress; desk idle (born 49.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio await-versions-not-info --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/builder-stamp-misses-reviewer-guard` | worktree | Hidden worktree; branch `feat/builder-stamp-misses-reviewer-guard` is clean and HEAD fc90d8ca is contained in origin/accepted; health down, Redis DB 59, database mcritchie_studio_development_builder_stamp_misses_revi_263c99b4:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/builder-stamp-misses-reviewer-guard (GitHub asked); no live build claim on builder-stamp-misses-reviewer-guard; no review in progress; desk idle (born 114.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio builder-stamp-misses-reviewer-guard --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/catch-migration-collision-at-merge` | worktree | Hidden worktree; branch `feat/catch-migration-collision-at-merge` is clean and HEAD 9754dc07 is contained in origin/accepted; health down, Redis DB 10, database mcritchie_studio_development_catch_migration_collision_at_merge:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/catch-migration-collision-at-merge (GitHub asked); no live build claim on catch-migration-collision-at-merge; no review in progress; desk idle (born 97.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio catch-migration-collision-at-merge --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/certify-accepted-on-push` | worktree | Hidden worktree; branch `feat/certify-accepted-on-push` is clean and HEAD 7ac7155d is contained in origin/accepted; health down, Redis DB 32, database mcritchie_studio_development_certify_accepted_on_push:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/certify-accepted-on-push (GitHub asked); no live build claim on certify-accepted-on-push; no review in progress; desk idle (born 84.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio certify-accepted-on-push --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/cleanup-sweep-orphans-live-work` | worktree | Hidden worktree; branch `feat/cleanup-sweep-orphans-live-work` is clean and HEAD 1d9accdd is contained in origin/accepted; health down, Redis DB 21, database mcritchie_studio_development_cleanup_sweep_orphans_live_work:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/cleanup-sweep-orphans-live-work (GitHub asked); no live build claim on cleanup-sweep-orphans-live-work; no review in progress; desk idle (born 97.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio cleanup-sweep-orphans-live-work --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/dependabot-targets-accepted-branch` | worktree | Hidden worktree; branch `feat/dependabot-targets-accepted-branch` is clean and HEAD ae0aa3a6 is contained in origin/accepted; health down, Redis DB 13, database mcritchie_studio_development_dependabot_targets_accepted_branch:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/dependabot-targets-accepted-branch (GitHub asked); no live build claim on dependabot-targets-accepted-branch; no review in progress; desk idle (born 97.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio dependabot-targets-accepted-branch --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/detect-engine-migration-content-drift` | worktree | Hidden worktree; branch `feat/detect-engine-migration-content-drift` is clean and HEAD 4525884f is contained in origin/accepted; health up, Redis DB 22, database mcritchie_studio_development_detect_engine_migration_c_27c3b1b6:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/detect-engine-migration-content-drift (GitHub asked); no live build claim on detect-engine-migration-content-drift; no review in progress; desk idle (born 97.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio detect-engine-migration-content-drift --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/document-shared-aws-credential-scope` | worktree | Hidden worktree; branch `feat/document-shared-aws-credential-scope` is clean and HEAD fc29cf9f is contained in origin/accepted; health down, Redis DB 16, database mcritchie_studio_development_document_shared_aws_crede_7bcde5f3:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/document-shared-aws-credential-scope (GitHub asked); no live build claim on document-shared-aws-credential-scope; no review in progress; desk idle (born 114.3h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio document-shared-aws-credential-scope --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/dor-check-loads-plugins` | worktree | Hidden worktree; branch `feat/dor-check-loads-plugins` is clean and HEAD ee069e88 is contained in origin/accepted; health down, Redis DB 29, database mcritchie_studio_development_dor_check_loads_plugins:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/dor-check-loads-plugins (GitHub asked); no live build claim on dor-check-loads-plugins; no review in progress; desk idle (born 84.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio dor-check-loads-plugins --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/e2e-collector-catches-third-party` | worktree | Hidden worktree; branch `feat/e2e-collector-catches-third-party` is clean and HEAD 97f2f4f0 is contained in origin/accepted; health down, Redis DB 53, database mcritchie_studio_development_e2e_collector_catches_third_party:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/e2e-collector-catches-third-party (GitHub asked); no live build claim on e2e-collector-catches-third-party; no review in progress; desk idle (born 114.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio e2e-collector-catches-third-party --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-at-time-midnight-bomb` | worktree | Hidden worktree; branch `feat/fix-at-time-midnight-bomb` is clean and HEAD 49f7d4b9 is contained in origin/accepted; health down, Redis DB 43, database mcritchie_studio_development_fix_at_time_midnight_bomb:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/fix-at-time-midnight-bomb (GitHub asked); no live build claim on fix-at-time-midnight-bomb; no review in progress; desk idle (born 72.1h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio fix-at-time-midnight-bomb --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/freeze-test-hotspot-growth` | worktree | Hidden worktree; branch `feat/freeze-test-hotspot-growth` is clean and HEAD c5a72fe5 is contained in origin/accepted; health down, Redis DB 37, database mcritchie_studio_development_freeze_test_hotspot_growth:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/freeze-test-hotspot-growth (GitHub asked); no live build claim on freeze-test-hotspot-growth; no review in progress; desk idle (born 82.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio freeze-test-hotspot-growth --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/gate-accepts-stale-ci-verdict` | worktree | Hidden worktree; branch `feat/gate-accepts-stale-ci-verdict` is clean and HEAD ede291c4 is contained in origin/accepted; health down, Redis DB 25, database mcritchie_studio_development_gate_accepts_stale_ci_verdict:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/gate-accepts-stale-ci-verdict (GitHub asked); no live build claim on gate-accepts-stale-ci-verdict; no review in progress; desk idle (born 97.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio gate-accepts-stale-ci-verdict --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/guard-every-promote-caller` | worktree | Hidden worktree; branch `feat/guard-every-promote-caller` is clean and HEAD 1ae243e3 is contained in origin/accepted; health down, Redis DB 33, database mcritchie_studio_development_guard_every_promote_caller:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/guard-every-promote-caller (GitHub asked); no live build claim on guard-every-promote-caller; no review in progress; desk idle (born 83.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio guard-every-promote-caller --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/install-standard-profile-columns` | worktree | Hidden worktree; branch `feat/install-standard-profile-columns` is clean and HEAD 137c96da is contained in origin/accepted; health down, Redis DB 42, database mcritchie_studio_development_install_standard_profile_columns:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/install-standard-profile-columns (GitHub asked); no live build claim on install-standard-profile-columns; no review in progress; desk idle (born 72.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio install-standard-profile-columns --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/merge-promotes-every-repo` | worktree | Hidden worktree; branch `feat/merge-promotes-every-repo` is clean and HEAD 8e7c5e21 is contained in origin/accepted; health down, Redis DB 34, database mcritchie_studio_development_merge_promotes_every_repo:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/merge-promotes-every-repo (GitHub asked); no live build claim on merge-promotes-every-repo; no review in progress; desk idle (born 106.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio merge-promotes-every-repo --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/retime-evolution-and-card-rings` | worktree | Hidden worktree; branch `feat/retime-evolution-and-card-rings` is clean and HEAD fcd1a8e3 is contained in origin/accepted; health up, Redis DB 55, database mcritchie_studio_development_retime_evolution_and_card_rings:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/retime-evolution-and-card-rings (GitHub asked); no live build claim on retime-evolution-and-card-rings; no review in progress; desk idle (born 59.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio retime-evolution-and-card-rings --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/test-health-ratchet-gate` | worktree | Hidden worktree; branch `feat/test-health-ratchet-gate` is clean and HEAD 8179997e is contained in origin/accepted; health down, Redis DB 35, database mcritchie_studio_development_test_health_ratchet_gate:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/test-health-ratchet-gate (GitHub asked); no live build claim on test-health-ratchet-gate; no review in progress; desk idle (born 82.8h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio test-health-ratchet-gate --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/ui-edit-preserves-devops-keys` | worktree | Hidden worktree; branch `feat/ui-edit-preserves-devops-keys` is clean and HEAD c8f5f13a is contained in origin/accepted; health down, Redis DB 9, database mcritchie_studio_development_ui_edit_preserves_devops_keys:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/ui-edit-preserves-devops-keys (GitHub asked); no live build claim on ui-edit-preserves-devops-keys; no review in progress; desk idle (born 97.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio ui-edit-preserves-devops-keys --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/wire-industries-ci-webhook` | worktree | Hidden worktree; branch `feat/wire-industries-ci-webhook` is clean and HEAD b0eac7e5 is contained in origin/accepted; health down, Redis DB 19, database mcritchie_studio_development_wire_industries_ci_webhook:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/wire-industries-ci-webhook (GitHub asked); no live build claim on wire-industries-ci-webhook; no review in progress; desk idle (born 97.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-studio wire-industries-ci-webhook --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/turf-monster/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD 4ecc241 is contained in origin/accepted; health missing-env, Redis DB , database unknown Cleared: merged into origin/accepted, tree clean; no open PR for (detached — no branch) (GitHub asked); no live release conductor claim (assembler/deployer); desk idle (born 64.0h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster _ship --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/turf-monster/.worktrees/adopt-shared-birthday-field` | worktree | Hidden worktree; branch `feat/adopt-shared-birthday-field` is clean and HEAD 533f5d7 is contained in origin/accepted; health up, Redis DB 46, database turf_monster_development_adopt_shared_birthday_field:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/adopt-shared-birthday-field (GitHub asked); no live build claim on adopt-shared-birthday-field; no review in progress; desk idle (born 61.7h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster adopt-shared-birthday-field --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/turf-monster/.worktrees/await-versions-not-info` | worktree | Hidden worktree; branch `feat/await-versions-not-info` is clean and HEAD 3444b3a is contained in origin/accepted; health down, Redis DB 61, database turf_monster_development_await_versions_not_info:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/await-versions-not-info (GitHub asked); no live build claim on await-versions-not-info; no review in progress; desk idle (born 49.5h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster await-versions-not-info --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/turf-monster/.worktrees/dependabot-targets-accepted-branch` | worktree | Hidden worktree; branch `feat/dependabot-targets-accepted-branch` is clean and HEAD d9c88d3 is contained in origin/accepted; health down, Redis DB 17, database turf_monster_development_dependabot_targets_accepted_branch:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/dependabot-targets-accepted-branch (GitHub asked); no live build claim on dependabot-targets-accepted-branch; no review in progress; desk idle (born 97.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster dependabot-targets-accepted-branch --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/turf-monster/.worktrees/detect-engine-migration-content-drift` | worktree | Hidden worktree; branch `feat/detect-engine-migration-content-drift` is clean and HEAD 1ce8e36 is contained in origin/accepted; health down, Redis DB 23, database turf_monster_development_detect_engine_migration_content_drift:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/detect-engine-migration-content-drift (GitHub asked); no live build claim on detect-engine-migration-content-drift; no review in progress; desk idle (born 97.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster detect-engine-migration-content-drift --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/turf-monster/.worktrees/fizzy-hold-button-effect` | worktree | Hidden worktree; branch `feat/fizzy-hold-button-effect` is clean and HEAD dca98ab is contained in origin/accepted; health up, Redis DB 54, database turf_monster_development_fizzy_hold_button_effect:ok Cleared: merged into origin/accepted, tree clean; no open PR for feat/fizzy-hold-button-effect (GitHub asked); no live build claim on fizzy-hold-button-effect; no review in progress; desk idle (born 59.9h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster fizzy-hold-button-effect --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/turf-monster/.worktrees/set-turf-wallet-method` | worktree | Hidden worktree; branch `feat/set-turf-wallet-method` is clean and HEAD ddde407 is contained in origin/accepted; health down, Redis DB 38, database turf_monster_development_set_turf_wallet_method:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/set-turf-wallet-method (GitHub asked); no live build claim on set-turf-wallet-method; no review in progress; desk idle (born 80.2h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove turf-monster set-turf-wallet-method --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/dependabot-targets-accepted-branch` | worktree | Hidden worktree; branch `feat/dependabot-targets-accepted-branch` is clean and HEAD 019e5d4 is contained in origin/accepted; health down, Redis DB 18, database mcritchie_industries_development_dependabot_targets_ac_302370e9:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/dependabot-targets-accepted-branch (GitHub asked); no live build claim on dependabot-targets-accepted-branch; no review in progress; desk idle (born 97.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-industries dependabot-targets-accepted-branch --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/detect-engine-migration-content-drift` | worktree | Hidden worktree; branch `feat/detect-engine-migration-content-drift` is clean and HEAD cd8ef0a is contained in origin/accepted; health down, Redis DB 24, database mcritchie_industries_development_detect_engine_migrati_27c3b1b6:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/detect-engine-migration-content-drift (GitHub asked); no live build claim on detect-engine-migration-content-drift; no review in progress; desk idle (born 97.6h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-industries detect-engine-migration-content-drift --yes` during approved lifecycle cleanup. | removed 2026-08-18 |

<!-- agent-worktree remove 2026-08-18 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/industries-apex-drops-path` | worktree | Hidden worktree; branch `feat/industries-apex-drops-path` is clean and HEAD 61a438a is contained in origin/accepted; health down, Redis DB 15, database mcritchie_industries_development_industries_apex_drops_path:missing Cleared: merged into origin/accepted, tree clean; no open PR for feat/industries-apex-drops-path (GitHub asked); no live build claim on industries-apex-drops-path; no review in progress; desk idle (born 114.4h ago, no writes in the last 1.5h). | Removed with `bin/agent-worktree remove mcritchie-industries industries-apex-drops-path --yes` during approved lifecycle cleanup. | removed 2026-08-18 |
