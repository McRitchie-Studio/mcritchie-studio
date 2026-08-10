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
| `/Users/alex/projects/turf-monster/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD 1eb9d2f is contained in origin/accepted; health missing-env, Redis DB , database unknown. | Removed with `bin/agent-worktree remove turf-monster _ship --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

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
| `/Users/alex/projects/mcritchie-studio/.worktrees/glow-changed-release-meter` | worktree | Hidden worktree; branch `feat/glow-changed-release-meter` is clean and HEAD a4fc8e1b is contained in origin/accepted; health port-busy, Redis DB 11, database mcritchie_studio_development_glow_changed_release_meter:ok. | Removed with `bin/agent-worktree remove mcritchie-studio glow-changed-release-meter --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

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
| `/Users/alex/projects/mcritchie-industries/.worktrees/_ship` | worktree | Hidden worktree; branch `` is clean and HEAD a7bec7e is contained in origin/accepted; health missing-env, Redis DB , database unknown. | Removed with `bin/agent-worktree remove mcritchie-industries _ship --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

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
| `/Users/alex/projects/mcritchie-studio/.worktrees/authenticate-agent-activities-e2e-specs` | worktree | Hidden worktree; branch `feat/authenticate-agent-activities-e2e-specs` is clean and HEAD 640e6a96 is contained in origin/accepted; health down, Redis DB 16, database mcritchie_studio_development_authenticate_agent_activi_cfede473:missing. | Removed with `bin/agent-worktree remove mcritchie-studio authenticate-agent-activities-e2e-specs --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/cap-activity-drilldown-actions` | worktree | Hidden worktree; branch `feat/cap-activity-drilldown-actions` is clean and HEAD 37f090b7 is contained in origin/accepted; health down, Redis DB 32, database mcritchie_studio_development_cap_activity_drilldown_actions:missing. | Removed with `bin/agent-worktree remove mcritchie-studio cap-activity-drilldown-actions --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/cleanup-handles-unmerged-desks` | worktree | Hidden worktree; branch `feat/cleanup-handles-unmerged-desks` is clean and HEAD ac54a3e3 is contained in origin/accepted; health down, Redis DB 9, database mcritchie_studio_development_cleanup_handles_unmerged_desks:missing. | Removed with `bin/agent-worktree remove mcritchie-studio cleanup-handles-unmerged-desks --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/clear-ready-flags-on-cache` | worktree | Hidden worktree; branch `feat/clear-ready-flags-on-cache` is clean and HEAD 603f41ba is contained in origin/accepted; health down, Redis DB 35, database mcritchie_studio_development_clear_ready_flags_on_cache:missing. | Removed with `bin/agent-worktree remove mcritchie-studio clear-ready-flags-on-cache --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/dor-check-review-rooting` | worktree | Hidden worktree; branch `feat/dor-check-review-rooting` is clean and HEAD 70ad0738 is contained in origin/accepted; health down, Redis DB 12, database mcritchie_studio_development_dor_check_review_rooting:missing. | Removed with `bin/agent-worktree remove mcritchie-studio dor-check-review-rooting --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/findings-triage-inbox` | worktree | Hidden worktree; branch `feat/findings-triage-inbox` is clean and HEAD ddeccb9a is contained in origin/accepted; health down, Redis DB 29, database mcritchie_studio_development_findings_triage_inbox:missing. | Removed with `bin/agent-worktree remove mcritchie-studio findings-triage-inbox --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-forward-review-rubric` | worktree | Hidden worktree; branch `feat/fix-forward-review-rubric` is clean and HEAD 0231bc24 is contained in origin/accepted; health down, Redis DB 27, database mcritchie_studio_development_fix_forward_review_rubric:missing. | Removed with `bin/agent-worktree remove mcritchie-studio fix-forward-review-rubric --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-glow-color-space-guard` | worktree | Hidden worktree; branch `feat/fix-glow-color-space-guard` is clean and HEAD dc275c38 is contained in origin/accepted; health down, Redis DB 23, database mcritchie_studio_development_fix_glow_color_space_guard:ok. | Removed with `bin/agent-worktree remove mcritchie-studio fix-glow-color-space-guard --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-lock-test-path-collision` | worktree | Hidden worktree; branch `feat/fix-lock-test-path-collision` is clean and HEAD def3c372 is contained in origin/accepted; health down, Redis DB 36, database mcritchie_studio_development_fix_lock_test_path_collision:missing. | Removed with `bin/agent-worktree remove mcritchie-studio fix-lock-test-path-collision --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/harden-release-merge-forward-guard` | worktree | Hidden worktree; branch `feat/harden-release-merge-forward-guard` is clean and HEAD c228d0ca is contained in origin/accepted; health down, Redis DB 21, database mcritchie_studio_development_harden_release_merge_forward_guard:missing. | Removed with `bin/agent-worktree remove mcritchie-studio harden-release-merge-forward-guard --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/hub-adopts-engine-sidebar` | worktree | Hidden worktree; branch `feat/hub-adopts-engine-sidebar` is clean and HEAD 9359f43b is contained in origin/accepted; health down, Redis DB 19, database mcritchie_studio_development_hub_adopts_engine_sidebar:missing. | Removed with `bin/agent-worktree remove mcritchie-studio hub-adopts-engine-sidebar --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/ingest-rerun-conclusion-updates` | worktree | Hidden worktree; branch `feat/ingest-rerun-conclusion-updates` is clean and HEAD 4805604e is contained in origin/accepted; health down, Redis DB 63, database mcritchie_studio_development_ingest_rerun_conclusion_updates:missing. | Removed with `bin/agent-worktree remove mcritchie-studio ingest-rerun-conclusion-updates --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/lock-origin-behind-cdn` | worktree | Hidden worktree; branch `feat/lock-origin-behind-cdn` is clean and HEAD c19c98da is contained in origin/accepted; health down, Redis DB 14, database mcritchie_studio_development_lock_origin_behind_cdn:missing. | Removed with `bin/agent-worktree remove mcritchie-studio lock-origin-behind-cdn --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/merge-forward-gem-repos` | worktree | Hidden worktree; branch `feat/merge-forward-gem-repos` is clean and HEAD d8741618 is contained in origin/accepted; health down, Redis DB 33, database mcritchie_studio_development_merge_forward_gem_repos:missing. | Removed with `bin/agent-worktree remove mcritchie-studio merge-forward-gem-repos --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/raise-hub-web-concurrency` | worktree | Hidden worktree; branch `feat/raise-hub-web-concurrency` is clean and HEAD aedc7d12 is contained in origin/accepted; health down, Redis DB 34, database mcritchie_studio_development_raise_hub_web_concurrency:missing. | Removed with `bin/agent-worktree remove mcritchie-studio raise-hub-web-concurrency --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/self-heal-session-mascot` | worktree | Hidden worktree; branch `feat/self-heal-session-mascot` is clean and HEAD d0a40a33 is contained in origin/accepted; health down, Redis DB 22, database mcritchie_studio_development_self_heal_session_mascot:missing. | Removed with `bin/agent-worktree remove mcritchie-studio self-heal-session-mascot --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/sticky-session-genesis-slug` | worktree | Hidden worktree; branch `feat/sticky-session-genesis-slug` is clean and HEAD 8fd55b1a is contained in origin/accepted; health down, Redis DB 26, database mcritchie_studio_development_sticky_session_genesis_slug:missing. | Removed with `bin/agent-worktree remove mcritchie-studio sticky-session-genesis-slug --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/verify-gem-lock-bump-landed` | worktree | Hidden worktree; branch `feat/verify-gem-lock-bump-landed` is clean and HEAD 5ee2f44f is contained in origin/accepted; health down, Redis DB 20, database mcritchie_studio_development_verify_gem_lock_bump_landed:missing. | Removed with `bin/agent-worktree remove mcritchie-studio verify-gem-lock-bump-landed --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/turf-monster/.worktrees/adopt-reclick-semantics-turf` | worktree | Hidden worktree; branch `feat/adopt-reclick-semantics-turf` is clean and HEAD 309808e is contained in origin/accepted; health down, Redis DB 17, database turf_monster_development_adopt_reclick_semantics_turf:missing. | Removed with `bin/agent-worktree remove turf-monster adopt-reclick-semantics-turf --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/turf-monster/.worktrees/correct-stale-navbar-doc-sections` | worktree | Hidden worktree; branch `feat/correct-stale-navbar-doc-sections` is clean and HEAD 23cff19 is contained in origin/accepted; health down, Redis DB 10, database turf_monster_development_correct_stale_navbar_doc_sections:missing. | Removed with `bin/agent-worktree remove turf-monster correct-stale-navbar-doc-sections --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/turf-monster/.worktrees/correct-turf-ui-patterns-docs` | worktree | Hidden worktree; branch `feat/correct-turf-ui-patterns-docs` is clean and HEAD 89052c6 is contained in origin/accepted; health down, Redis DB 15, database turf_monster_development_correct_turf_ui_patterns_docs:missing. | Removed with `bin/agent-worktree remove turf-monster correct-turf-ui-patterns-docs --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/turf-monster/.worktrees/flip-modal-contrast-guard` | worktree | Hidden worktree; branch `feat/flip-modal-contrast-guard` is clean and HEAD d6099f1 is contained in origin/accepted; health down, Redis DB 13, database turf_monster_development_flip_modal_contrast_guard:missing. | Removed with `bin/agent-worktree remove turf-monster flip-modal-contrast-guard --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/turf-monster/.worktrees/pin-multi-week-ordering` | worktree | Hidden worktree; branch `feat/pin-multi-week-ordering` is clean and HEAD 40af013 is contained in origin/accepted; health down, Redis DB 24, database turf_monster_development_pin_multi_week_ordering:missing. | Removed with `bin/agent-worktree remove turf-monster pin-multi-week-ordering --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/adopt-brand-color-palette` | worktree | Hidden worktree; branch `feat/adopt-brand-color-palette` is clean and HEAD dff5696 is contained in origin/accepted; health up, Redis DB 59, database mcritchie_industries_development_adopt_brand_color_palette:ok. | Removed with `bin/agent-worktree remove mcritchie-industries adopt-brand-color-palette --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/industries-declares-sidebar-sections` | worktree | Hidden worktree; branch `feat/industries-declares-sidebar-sections` is clean and HEAD cba6079 is contained in origin/accepted; health up, Redis DB 18, database mcritchie_industries_development_industries_declares_s_13988527:ok. | Removed with `bin/agent-worktree remove mcritchie-industries industries-declares-sidebar-sections --yes` during approved lifecycle cleanup. | removed 2026-08-10 |

<!-- agent-worktree remove 2026-08-10 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/industries-landing-page-replica` | worktree | Hidden worktree; branch `feat/industries-landing-page-replica` is clean and HEAD 78168d4 is contained in origin/accepted; health down, Redis DB 57, database mcritchie_industries_development_industries_landing_pa_9a99e18c:ok. | Removed with `bin/agent-worktree remove mcritchie-industries industries-landing-page-replica --yes` during approved lifecycle cleanup. | removed 2026-08-10 |
