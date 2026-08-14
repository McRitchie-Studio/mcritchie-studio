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
| `/Users/alex/projects/mcritchie-industries/.worktrees/pin-ruby-vips-explicitly` | worktree | Hidden worktree; branch `feat/pin-ruby-vips-explicitly` is clean and HEAD cebf07a is contained in origin/accepted; health down, Redis DB 57, database mcritchie_industries_development_pin_ruby_vips_explicitly:missing. | Removed with `bin/agent-worktree remove mcritchie-industries pin-ruby-vips-explicitly --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/brakeman-scans-before-version-check` | worktree | Hidden worktree; branch `feat/brakeman-scans-before-version-check` is clean and HEAD 2990b9b is contained in origin/accepted; health down, Redis DB 18, database mcritchie_industries_development_brakeman_scans_before_99231b22:missing. | Removed with `bin/agent-worktree remove mcritchie-industries brakeman-scans-before-version-check --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/industries-ephemeral-storage-trap` | worktree | Hidden worktree; branch `feat/industries-ephemeral-storage-trap` is clean and HEAD 341ce57 is contained in origin/accepted; health down, Redis DB 33, database mcritchie_industries_development_industries_ephemeral__f0c2cda3:missing. | Removed with `bin/agent-worktree remove mcritchie-industries industries-ephemeral-storage-trap --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-industries/.worktrees/industries-seed-member-user` | worktree | Hidden worktree; branch `feat/industries-seed-member-user` is clean and HEAD 0f9d8aa is contained in origin/accepted; health down, Redis DB 36, database mcritchie_industries_development_industries_seed_member_user:missing. | Removed with `bin/agent-worktree remove mcritchie-industries industries-seed-member-user --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/audit-industries-tier-collectability` | worktree | Hidden worktree; branch `feat/audit-industries-tier-collectability` is clean and HEAD 2e75b0aa is contained in origin/accepted; health down, Redis DB 50, database mcritchie_studio_development_audit_industries_tier_col_e2fb1387:missing. | Removed with `bin/agent-worktree remove mcritchie-studio audit-industries-tier-collectability --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/close-email-copy-coverage-gaps` | worktree | Hidden worktree; branch `feat/close-email-copy-coverage-gaps` is clean and HEAD ed038200 is contained in origin/accepted; health down, Redis DB 29, database mcritchie_studio_development_close_email_copy_coverage_gaps:missing. | Removed with `bin/agent-worktree remove mcritchie-studio close-email-copy-coverage-gaps --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/drop-hub-bars-var-assertion` | worktree | Hidden worktree; branch `feat/drop-hub-bars-var-assertion` is clean and HEAD 463366b5 is contained in origin/accepted; health down, Redis DB 21, database mcritchie_studio_development_drop_hub_bars_var_assertion:missing. | Removed with `bin/agent-worktree remove mcritchie-studio drop-hub-bars-var-assertion --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/escape-insight-label-and-slug` | worktree | Hidden worktree; branch `feat/escape-insight-label-and-slug` is clean and HEAD 6067095a is contained in origin/accepted; health down, Redis DB 17, database mcritchie_studio_development_escape_insight_label_and_slug:missing. | Removed with `bin/agent-worktree remove mcritchie-studio escape-insight-label-and-slug --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-token-remedy-lane-crossing` | worktree | Hidden worktree; branch `feat/fix-token-remedy-lane-crossing` is clean and HEAD 7717f881 is contained in origin/accepted; health down, Redis DB 38, database mcritchie_studio_development_fix_token_remedy_lane_crossing:missing. | Removed with `bin/agent-worktree remove mcritchie-studio fix-token-remedy-lane-crossing --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/land-rails-security-patch` | worktree | Hidden worktree; branch `feat/land-rails-security-patch` is clean and HEAD 98f8e44e is contained in origin/accepted; health down, Redis DB 44, database mcritchie_studio_development_land_rails_security_patch:missing. | Removed with `bin/agent-worktree remove mcritchie-studio land-rails-security-patch --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/lane-create-race-raises-instead` | worktree | Hidden worktree; branch `feat/lane-create-race-raises-instead` is clean and HEAD 6b86a859 is contained in origin/accepted; health down, Redis DB 12, database mcritchie_studio_development_lane_create_race_raises_instead:missing. | Removed with `bin/agent-worktree remove mcritchie-studio lane-create-race-raises-instead --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/lease-outlives-idle-session` | worktree | Hidden worktree; branch `feat/lease-outlives-idle-session` is clean and HEAD 99824322 is contained in origin/accepted; health down, Redis DB 41, database mcritchie_studio_development_lease_outlives_idle_session:missing. | Removed with `bin/agent-worktree remove mcritchie-studio lease-outlives-idle-session --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/let-agents-record-approval` | worktree | Hidden worktree; branch `feat/let-agents-record-approval` is clean and HEAD bb9c042b is contained in origin/accepted; health down, Redis DB 22, database mcritchie_studio_development_let_agents_record_approval:ok. | Removed with `bin/agent-worktree remove mcritchie-studio let-agents-record-approval --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/promote-reaches-assembled-candidate` | worktree | Hidden worktree; branch `feat/promote-reaches-assembled-candidate` is clean and HEAD 0c82735c is contained in origin/accepted; health down, Redis DB 48, database mcritchie_studio_development_promote_reaches_assembled_9074f649:missing. | Removed with `bin/agent-worktree remove mcritchie-studio promote-reaches-assembled-candidate --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/retro-refiles-duplicate-findings` | worktree | Hidden worktree; branch `feat/retro-refiles-duplicate-findings` is clean and HEAD 6c5b2154 is contained in origin/accepted; health down, Redis DB 43, database mcritchie_studio_development_retro_refiles_duplicate_findings:missing. | Removed with `bin/agent-worktree remove mcritchie-studio retro-refiles-duplicate-findings --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/review-gate-fails-closed` | worktree | Hidden worktree; branch `feat/review-gate-fails-closed` is clean and HEAD 4c1d42a5 is contained in origin/accepted; health down, Redis DB 25, database mcritchie_studio_development_review_gate_fails_closed:missing. | Removed with `bin/agent-worktree remove mcritchie-studio review-gate-fails-closed --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/reviewer-merges-mint-tokens` | worktree | Hidden worktree; branch `feat/reviewer-merges-mint-tokens` is clean and HEAD 23ebcea3 is contained in origin/accepted; health down, Redis DB 16, database mcritchie_studio_development_reviewer_merges_mint_tokens:missing. | Removed with `bin/agent-worktree remove mcritchie-studio reviewer-merges-mint-tokens --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/standardize-ci-read-auth` | worktree | Hidden worktree; branch `feat/standardize-ci-read-auth` is clean and HEAD f74be9ef is contained in origin/accepted; health down, Redis DB 32, database mcritchie_studio_development_standardize_ci_read_auth:missing. | Removed with `bin/agent-worktree remove mcritchie-studio standardize-ci-read-auth --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/task-card-exit-assertion-races` | worktree | Hidden worktree; branch `feat/task-card-exit-assertion-races` is clean and HEAD 694ecd43 is contained in origin/accepted; health down, Redis DB 60, database mcritchie_studio_development_task_card_exit_assertion_races:missing. | Removed with `bin/agent-worktree remove mcritchie-studio task-card-exit-assertion-races --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/turf-monster/.worktrees/bump-turf-engine-pin` | worktree | Hidden worktree; branch `feat/bump-turf-engine-pin` is clean and HEAD f42d29c is contained in origin/accepted; health down, Redis DB 15, database turf_monster_development_bump_turf_engine_pin:ok. | Removed with `bin/agent-worktree remove turf-monster bump-turf-engine-pin --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/turf-monster/.worktrees/land-rails-security-patch` | worktree | Hidden worktree; branch `feat/land-rails-security-patch` is clean and HEAD 5ec09aa is contained in origin/accepted; health down, Redis DB 46, database turf_monster_development_land_rails_security_patch:missing. | Removed with `bin/agent-worktree remove turf-monster land-rails-security-patch --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/turf-monster/.worktrees/post-auth-onboarding-flow` | worktree | Hidden worktree; branch `feat/post-auth-onboarding-flow` is clean and HEAD d58a8a7 is contained in origin/accepted; health down, Redis DB 9, database turf_monster_development_post_auth_onboarding_flow:ok. | Removed with `bin/agent-worktree remove turf-monster post-auth-onboarding-flow --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/turf-monster/.worktrees/repoint-admin-emails-upload-spec` | worktree | Hidden worktree; branch `feat/repoint-admin-emails-upload-spec` is clean and HEAD 4eb7596 is contained in origin/accepted; health down, Redis DB 23, database turf_monster_development_repoint_admin_emails_upload_spec:missing. | Removed with `bin/agent-worktree remove turf-monster repoint-admin-emails-upload-spec --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/turf-monster/.worktrees/turf-email-settings-schema-drift` | worktree | Hidden worktree; branch `feat/turf-email-settings-schema-drift` is clean and HEAD e7307be is contained in origin/accepted; health down, Redis DB 47, database turf_monster_development_turf_email_settings_schema_drift:missing. | Removed with `bin/agent-worktree remove turf-monster turf-email-settings-schema-drift --yes` during approved lifecycle cleanup. | removed 2026-08-13 |

<!-- agent-worktree remove 2026-08-13 -->
| `/Users/alex/projects/turf-monster/.worktrees/turf-seed-house-admin` | worktree | Hidden worktree; branch `feat/turf-seed-house-admin` is clean and HEAD 48eaf3c is contained in origin/accepted; health down, Redis DB 35, database turf_monster_development_turf_seed_house_admin:missing. | Removed with `bin/agent-worktree remove turf-monster turf-seed-house-admin --yes` during approved lifecycle cleanup. | removed 2026-08-13 |
