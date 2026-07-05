# Delete Later Ledger

This ledger tracks files and directories that look removable once replacement docs, merged PRs, or migration checks are complete. Do not delete from this list without confirming the condition.

| Path | Type | Why it is a candidate | Safe-delete condition | Status |
|------|------|-----------------------|-----------------------|--------|
| `/Users/alex/projects/turf-monster-admin-error-logs` | worktree | Visible sibling worktree; current `turf-monster/main` already contains the useful admin error log work. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-allow-browser-preview-fix` | worktree | Visible sibling worktree; branch patch was equivalent to `origin/main` at cleanup classification. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-compliance` | worktree | Visible sibling worktree; `HEAD` was contained in `origin/main` at cleanup classification. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-cosign-entry-validation` | worktree | Visible sibling worktree; `HEAD` was contained in `origin/main` at cleanup classification. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-dashboard-dropdown-link` | worktree | Visible sibling worktree; current `turf-monster/main` already contains the admin dashboard dropdown link. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-docs-worktree-stack` | worktree | Visible sibling worktree; useful guidance was promoted to neutral McRitchie Studio docs. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-entry-confirmed-spinner` | worktree | Visible sibling worktree; `HEAD` was contained in `origin/main` at cleanup classification. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-paypal` | worktree | Visible sibling worktree; `HEAD` was contained in `origin/main` at cleanup classification. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-phantom-signing-order` | worktree | Visible sibling worktree; `HEAD` was contained in `origin/main` at cleanup classification. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-quest-mailing-list` | worktree | Visible sibling worktree; `HEAD` was contained in `origin/main` at cleanup classification. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-quest-navbar-cleanup` | worktree | Visible sibling worktree; current `turf-monster/main` already contains the useful navbar/link hub/vault state work. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-welcome-email` | worktree | Visible sibling worktree; old email work is obsolete relative to current `turf-monster/main` email infrastructure and would revert newer work if merged wholesale. | Removed with `git worktree remove`; empty wrapper containing only `tmp/` removed with `rm -rf`. | removed 2026-06-13 |
| `/Users/alex/projects/turf-vault/.worktrees/grant-seeds-salvage` | worktree | Hidden old feature worktree; `HEAD` is contained in `origin/main`, but dirty `Cargo.lock` was preserved for historical review. | Dirty `Cargo.lock` reviewed; no durable content remained. Worktree removed and local branch `feat/v0.22-grant-seeds` deleted. | removed 2026-06-14 |
| `/Users/alex/projects/turf-vault-v024-mainnet` | worktree | Old mainnet worktree; `HEAD` was contained in `origin/main` at cleanup classification. | Removed with `git worktree remove`. | removed 2026-06-13 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/broadcasts-salvage` | worktree | Hidden old feature worktree; still has 2 unique commits and dirty `docs/agents/system/email-delivery.md`. | Durable broadcast direction promoted into `modules/email-operations.md`; keep branch refs as historical source material. Worktree removed; branch `feat/broadcasts` retained. | removed 2026-06-14 |
| `*/CLAUDE.md` | docs | Legacy LLM-specific context. Archive-only banners added 2026-06-14. | Final review found no durable knowledge that only lived in these files; useful context is covered by README/RUNBOOK/topic docs and stale Claude-specific instructions were intentionally dropped. | removed 2026-06-14 |
| `turf-monster/docs/STASH_3_HANDOFF.md` | docs | Handoff-style document likely superseded by shipped work. | Archive-only salvage banner added; keep only as historical stash recovery context. | archive-only 2026-06-14 |
| `turf-monster/docs/ONCHAIN_UI_AUDIT_PROMPT.md` | docs | Prompt artifact, not active operational docs. Archive-only banner added 2026-06-14. | Useful scope promoted into `turf-monster/docs/SECURITY_REVIEW.md`; file deleted. | removed 2026-06-14 |
| `turf-monster/docs/REFACTOR_AUDIT_2026_05_23.md` | docs | Dated audit likely should be archived once still-live findings are promoted. | Archive-only banner added; current status lives in app docs and June ecosystem audits. | archive-only 2026-06-14 |
| `turf-monster/docs/SECURITY_AUDIT_2026_05_23.md` | docs | Historical security audit; may contain stale production assumptions. | Archive-only banner added; use newer security docs and current app runbooks before acting on any item. | archive-only 2026-06-14 |
| `turf-monster/docs/TESTS_TO_ADD.md` | docs | Backlog-style doc likely overlaps with tests and issue tracking. | Superseded by `turf-monster/docs/TEST_COVERAGE_STATUS.md`; keep only for historical detail. | archive-only 2026-06-14 |
| `turf-monster/docs/TEST_COVERAGE_AUDIT_2026_05_24.md` | docs | Historical test audit contains stale "zero tests" claims. | Archive-only banner added; current status lives in `turf-monster/docs/TEST_COVERAGE_STATUS.md`. | archive-only 2026-06-14 |
| `turf-monster/docs/DEVNET_INTEGRATION_TESTS_TO_ADD.md` | docs | Historical devnet test plan may not reflect current CI. | Archive-only banner added; current status lives in `turf-monster/docs/TEST_COVERAGE_STATUS.md`. | archive-only 2026-06-14 |
| `turf-monster/DEVNET_REHEARSAL.md` | docs | Historical v0.15.0 rehearsal runbook for a retired launch shape. Archive-only banner added 2026-06-14. | Current proof lives in `turf-monster/docs/SOLANA.md`, `turf-vault/RUNBOOK.md`, and `turf-vault/docs/VERIFICATION_MATRIX.md`; file deleted. | removed 2026-06-14 |
| `mcritchie-studio/docs/agents/system/ecosystem-audit-prompt.md` | docs | Prompt artifact for Claude-era audit workflow. Archive-only banner added 2026-06-14. | Neutral process promoted into `docs/agents/modules/audit-playbook.md`; file deleted. | removed 2026-06-14 |
| `mcritchie-studio/docs/agents/system/ecosystem-audit-2026-05-17.md` | docs | Historical audit contains stale examples such as old ports/domains. | Archive-only banner added; current ecosystem state lives in `docs/ECOSYSTEM.md` and June audit docs. | archive-only 2026-06-14 |
| `mcritchie-studio/docs/agents/system/md-audit-2026-05-23.md` | docs | Historical drift audit. | Archive-only banner added; current drift checks live in `docs/agents/modules/docs-maintenance.md`. | archive-only 2026-06-14 |
| `/Users/alex/projects/dev-stack-smoothing.md` | root stray file | Root-level implementation brief for isolated worktree stacks. Valuable, but outside durable repo docs. | Live requirements promoted into `mcritchie-studio/docs/agents/modules/worktrees.md` and `mcritchie-studio/bin/agent-worktree`; root copy deleted. | removed 2026-06-14 |
| `/Users/alex/projects/bin/clean-artifacts` | root local script | Useful maintenance script, but duplicated into `mcritchie-studio/bin/clean-artifacts` during cleanup. | Tracked copy confirmed to cover the root layout via `PROJECTS_DIR` and broader repo/worktree reporting. Root script and empty `bin/` wrapper deleted. | removed 2026-06-14 |
| `/Users/alex/projects/turf-monster-cdp` | stray directory | Empty wrapper directory with only `tmp/`; not registered as a git worktree. | Removed after final local-file check showed no files. | removed 2026-06-13 |
| `/Users/alex/projects/turf-monster-og-config` | stray directory | Empty wrapper directory with only `tmp/`; not registered as a git worktree. | Removed after final local-file check showed no files. | removed 2026-06-13 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/admin-models-qa` | worktree | Hidden generated worktree; branch `feat/admin-models-qa` was clean and contained in `origin/main`. | Stopped stale local server process and removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/admin-models-refactor` | worktree | Hidden generated worktree; branch `feat/admin-models-refactor` was clean and contained in `origin/main`. | Stopped stale local server process and removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/agent-isolation-policy` | worktree | Hidden generated worktree; branch `feat/agent-isolation-policy` was clean and contained in `origin/main`. | Removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/chain-ops-localnet` | worktree | Hidden generated worktree; branch `feat/chain-ops-localnet` was clean and contained in `origin/main`. | Removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/final-audit-docket` | worktree | Hidden generated worktree; branch `feat/final-audit-docket` was clean and contained in `origin/main`. | Removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/link-sidebar-trigger-cleanup` | worktree | Hidden generated worktree; branch `feat/link-sidebar-trigger-cleanup` was clean and contained in `origin/main`. | Removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/parallel-agent-devops` | worktree | Hidden generated worktree; branch `feat/parallel-agent-devops` was clean and contained in `origin/main`. | Removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/ses-proof-credentials` | worktree | Hidden generated worktree; branch `feat/ses-proof-credentials` was clean and contained in `origin/main`. | Removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/turf-monster/.worktrees/admin-models-qa` | worktree | Hidden generated worktree; branch `feat/admin-models-qa` was clean and contained in `origin/main`. | Stopped stale local server process and removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/turf-monster/.worktrees/admin-models-refactor` | worktree | Hidden generated worktree; branch `feat/admin-models-refactor` was clean and contained in `origin/main`. | Stopped stale local server process and removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/turf-monster/.worktrees/cdp-phantom-create-hardening` | worktree | Hidden generated worktree; branch `feat/cdp-phantom-create-hardening` was clean and contained in `origin/main`. | Stopped stale local server process and removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/projects/turf-monster/.worktrees/nfl-starts-in-seeds` | worktree | Hidden generated worktree; branch `feat/nfl-starts-in-seeds` was clean and contained in `origin/main`. | Stopped stale local server process and removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-16 |
| `/Users/alex/.claude/projects/-Users-alex-projects/memory/*` | local memory | Local Claude memory contains useful historical feedback but should not be the durable source. | Durable lessons promoted into McRitchie Studio docs; keep local memory untouched unless the user asks. | reference only |
| `/Users/alex/.claude/agents/*.md` | local memory | Character files contain useful role expectations but are Claude-specific. | Neutral role/culture rules promoted into McRitchie Studio docs; keep local files untouched unless the user asks. | reference only |

<!-- agent-worktree cleanup 2026-06-17 -->
| `/Users/alex/projects/turf-monster/.worktrees/tailwind-v4-upgrade` | stale directory | Former hidden worktree path; Git no longer registered it as a worktree and it contained only `tmp/cache` bootsnap artifacts. | Removed the specific cache file, then removed the empty directory stack with `rmdir` during approved lifecycle cleanup. | removed 2026-06-17 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/broadcasts` | worktree | Hidden worktree; branch `feat/broadcasts` was squash-merged into `origin/main` by #8; final diff against current `origin/main` only reverted the QA banner helper/tests. | Stopped local web process on port 3001 and removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-17 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/qa-environment-banner` | worktree | Hidden worktree; branch `feat/qa-environment-banner` was squash-merged into `origin/main` by #22; final diff against current `origin/main` was empty. | Removed with `git worktree remove` during approved lifecycle cleanup. | removed 2026-06-17 |
| `/Users/alex/projects/mcritchie-studio/.worktrees/ai-builder-multiple-ui` | worktree | Hidden worktree; branch `feat/ai-builder-multiple-ui` was squash-merged into `origin/main` by #21; the old local branch only lacked later main commits from the QA banner and cleanup ledger. | Stopped local web process on port 3001, removed with `git worktree remove`, and deleted the stale local branch during closeout cleanup. | removed 2026-06-17 |
| `/private/tmp/mcritchie-pr21-merge` | temp worktree | Detached PR #21 merge-check worktree; dirty relative to old detached base but zero diff against current `main`. | Removed with `git worktree remove --force` after confirming no content diff against current `main`. | removed 2026-06-17 |
| `/Users/alex/projects/studio-engine/.worktrees/tailwind-v4-upgrade` | worktree | Studio Engine Tailwind v4 release worktree; branch `feat/tailwind-v4-upgrade` was fast-forwarded into `main` at `72c72eb`, tag `v0.6.0` was pushed, RubyGems `studio-engine (0.6.0)` was confirmed, and consumer apps were locked to `0.6.0`. | Removed with `git worktree remove`; merged local branch deleted with `git branch -d`; remote branch and release tag retained. | removed 2026-06-17 |
| `/Users/alex/projects/turf-monster/.worktrees/bot-admin-email` | worktree | Turf Monster PR #149 worktree; branch `feat/bot-admin-email` was squash-merged into `origin/main` as `ecf6154 Bot Admin Email (#149)`, and final diff from the branch to `origin/main` was empty. | Stopped the local stack on port 3101, removed with `git worktree remove`, and deleted the stale local branch. | removed 2026-06-17 |

<!-- agent-worktree cleanup 2026-06-18 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/devops-scout-launcher-v1` | worktree | Hidden worktree; branch `feat/devops-scout-launcher-v1` is clean and its final diff against origin/main is empty, usually after a squash merge. | Remove with `bin/agent-worktree remove mcritchie-studio devops-scout-launcher-v1 --yes` after operator approval. | pending approval |

<!-- agent-worktree cleanup 2026-06-19 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/devops-scout-control-v1` | worktree | Hidden worktree; branch `feat/devops-scout-control-v1` is clean and its final diff against origin/main is empty, usually after a squash merge. | Remove with `bin/agent-worktree remove mcritchie-studio devops-scout-control-v1 --yes` after operator approval. | pending approval |
| `/Users/alex/projects/mcritchie-studio/.worktrees/task-board-devops-contract` | worktree | Hidden worktree; branch `feat/task-board-devops-contract` is clean and its final diff against origin/main is empty, usually after a squash merge. | Remove with `bin/agent-worktree remove mcritchie-studio task-board-devops-contract --yes` after operator approval. | pending approval |
| `/Users/alex/projects/turf-monster/.worktrees/sidebar-back-qa-sync` | worktree | Hidden worktree; branch `feat/sidebar-back-qa-sync` is clean and its final diff against origin/main is empty, usually after a squash merge. | Remove with `bin/agent-worktree remove turf-monster sidebar-back-qa-sync --yes` after operator approval. | pending approval |

<!-- agent-worktree remove 2026-06-19 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/add-coach-admin-model` | worktree | Hidden worktree; branch `feat/add-coach-admin-model` is clean and its final diff against origin/main is empty, usually after a squash merge. | Removed with `bin/agent-worktree remove mcritchie-studio add-coach-admin-model --yes` during approved lifecycle cleanup. | removed 2026-06-19 |

<!-- agent-worktree remove 2026-06-21 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/readable-task-slugs` | worktree | Hidden worktree; branch `feat/readable-task-slugs` is clean and HEAD f8f0cbf is contained in origin/main. | Removed with `bin/agent-worktree remove mcritchie-studio readable-task-slugs --yes` during approved lifecycle cleanup. | removed 2026-06-21 |

<!-- agent-worktree remove 2026-06-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/cache-pokemon-primary-type` | worktree | Hidden worktree; branch `feat/cache-pokemon-primary-type` is clean and HEAD 7c738f0 is contained in origin/release. | Removed with `bin/agent-worktree remove mcritchie-studio cache-pokemon-primary-type --yes` during approved lifecycle cleanup. | removed 2026-06-25 |

<!-- agent-worktree remove 2026-06-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-wrap-verify-and-scope` | worktree | Hidden worktree; branch `feat/fix-wrap-verify-and-scope` is clean and HEAD 167a730 is contained in origin/release. | Removed with `bin/agent-worktree remove mcritchie-studio fix-wrap-verify-and-scope --yes` during approved lifecycle cleanup. | removed 2026-06-25 |

<!-- agent-worktree remove 2026-06-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/release-notes-header-refactor` | worktree | Hidden worktree; branch `feat/release-notes-header-refactor` is clean and HEAD 838a3e7 is contained in origin/release. | Removed with `bin/agent-worktree remove mcritchie-studio release-notes-header-refactor --yes` during approved lifecycle cleanup. | removed 2026-06-25 |

<!-- agent-worktree remove 2026-06-25 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/task-intelligence-dashboard` | worktree | Hidden worktree; branch `feat/task-intelligence-dashboard` is clean and HEAD 97f9bd0 is contained in origin/release. | Removed with `bin/agent-worktree remove mcritchie-studio task-intelligence-dashboard --yes` during approved lifecycle cleanup. | removed 2026-06-25 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/autonomous-release-sop` | worktree | Hidden worktree; branch `feat/autonomous-release-sop` is clean and HEAD e1f0e1c is contained in origin/release; health up, Redis DB 15, database mcritchie_studio_development_autonomous_release_sop:ok. | Removed with `bin/agent-worktree remove mcritchie-studio autonomous-release-sop --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/codex-startup-mascots` | worktree | Hidden worktree; branch `feat/codex-startup-mascots` is clean and HEAD 569664f is contained in origin/release; health down, Redis DB 18, database mcritchie_studio_development_codex_startup_mascots:missing. | Removed with `bin/agent-worktree remove mcritchie-studio codex-startup-mascots --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/docs-reference-sop-vocabulary` | worktree | Hidden worktree; branch `feat/docs-reference-sop-vocabulary` is clean and HEAD 3fd4078 is contained in origin/release; health down, Redis DB 11, database mcritchie_studio_development_docs_reference_sop_vocabulary:missing. | Removed with `bin/agent-worktree remove mcritchie-studio docs-reference-sop-vocabulary --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/live-codex-mascots` | worktree | Hidden worktree; branch `feat/live-codex-mascots` is clean and HEAD 44af659 is contained in origin/release; health down, Redis DB 26, database mcritchie_studio_development_live_codex_mascots:missing. | Removed with `bin/agent-worktree remove mcritchie-studio live-codex-mascots --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/preserve-mascot-history` | worktree | Hidden worktree; branch `feat/preserve-mascot-history` is clean and HEAD 43a20bb is contained in origin/release; health down, Redis DB 10, database mcritchie_studio_development_preserve_mascot_history:ok. | Removed with `bin/agent-worktree remove mcritchie-studio preserve-mascot-history --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/primary-owns-review-lane` | worktree | Hidden worktree; branch `feat/primary-owns-review-lane` is clean and HEAD c36e948 is contained in origin/release; health down, Redis DB 13, database mcritchie_studio_development_primary_owns_review_lane:missing. | Removed with `bin/agent-worktree remove mcritchie-studio primary-owns-review-lane --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/quiet-codex-mascots` | worktree | Hidden worktree; branch `feat/quiet-codex-mascots` is clean and HEAD e9c46fa is contained in origin/release; health down, Redis DB 25, database mcritchie_studio_development_quiet_codex_mascots:missing. | Removed with `bin/agent-worktree remove mcritchie-studio quiet-codex-mascots --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/release-tracker-pulse` | worktree | Hidden worktree; branch `feat/release-tracker-pulse` is clean and HEAD 237f30c is contained in origin/release; health up, Redis DB 20, database mcritchie_studio_development_release_tracker_pulse:ok. | Removed with `bin/agent-worktree remove mcritchie-studio release-tracker-pulse --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/review-timer-signal` | worktree | Hidden worktree; branch `feat/review-timer-signal` is clean and HEAD 169b0ef is contained in origin/release; health up, Redis DB 12, database mcritchie_studio_development_review_timer_signal:ok. | Removed with `bin/agent-worktree remove mcritchie-studio review-timer-signal --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/reviewer-roles-primary-light` | worktree | Hidden worktree; branch `feat/reviewer-roles-primary-light` is clean and HEAD d63780d is contained in origin/release; health down, Redis DB 9, database mcritchie_studio_development_reviewer_roles_primary_light:missing. | Removed with `bin/agent-worktree remove mcritchie-studio reviewer-roles-primary-light --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/rolio-deployment-integration` | worktree | Hidden worktree; branch `feat/rolio-deployment-integration` is clean and HEAD 8af7e92 is contained in origin/release; health down, Redis DB 23, database mcritchie_studio_development_rolio_deployment_integration:missing. | Removed with `bin/agent-worktree remove mcritchie-studio rolio-deployment-integration --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/task-card-overflow` | worktree | Hidden worktree; branch `feat/task-card-overflow` is clean and HEAD f7f76e8 is contained in origin/release; health up, Redis DB 22, database mcritchie_studio_development_task_card_overflow:ok. | Removed with `bin/agent-worktree remove mcritchie-studio task-card-overflow --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/archive-ledger-cleanup` | worktree | Hidden worktree; branch `feat/archive-ledger-cleanup` is clean and HEAD 01fd012 is contained in origin/release; health down, Redis DB 18, database mcritchie_studio_development_archive_ledger_cleanup:missing. | Removed with `bin/agent-worktree remove mcritchie-studio archive-ledger-cleanup --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/event-driven-lifecycle-apis` | worktree | Hidden worktree; branch `feat/event-driven-lifecycle-apis` is clean and HEAD 01df41c is contained in origin/release; health up, Redis DB 12, database mcritchie_studio_development_event_driven_lifecycle_apis:ok. | Removed with `bin/agent-worktree remove mcritchie-studio event-driven-lifecycle-apis --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/release-duration-dashboard` | worktree | Hidden worktree; branch `feat/release-duration-dashboard` is clean and HEAD d2aca9c is contained in origin/release; health down, Redis DB 11, database mcritchie_studio_development_release_duration_dashboard:missing. | Removed with `bin/agent-worktree remove mcritchie-studio release-duration-dashboard --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-06-28 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/studio-theme-polish` | worktree | Hidden worktree; branch `feat/studio-theme-polish` is clean and HEAD d2aca9c is contained in origin/release; health down, Redis DB 13, database mcritchie_studio_development_studio_theme_polish:missing. | Removed with `bin/agent-worktree remove mcritchie-studio studio-theme-polish --yes` during approved lifecycle cleanup. | removed 2026-06-28 |

<!-- agent-worktree remove 2026-07-01 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/agent-attribution-on-events` | worktree | Hidden worktree; branch `feat/agent-attribution-on-events` is clean and HEAD fdf1228 is contained in origin/release; health down, Redis DB 12, database mcritchie_studio_development_agent_attribution_on_events:missing. | Removed with `bin/agent-worktree remove mcritchie-studio agent-attribution-on-events --yes` during approved lifecycle cleanup. | removed 2026-07-01 |

<!-- agent-worktree remove 2026-07-01 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/agent-column-stacked-display` | worktree | Hidden worktree; branch `feat/agent-column-stacked-display` is clean and HEAD adaecf0 is contained in origin/release; health up, Redis DB 15, database mcritchie_studio_development_agent_column_stacked_display:ok. | Removed with `bin/agent-worktree remove mcritchie-studio agent-column-stacked-display --yes` during approved lifecycle cleanup. | removed 2026-07-01 |

<!-- agent-worktree remove 2026-07-01 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/avi-sizes-designed-tasks` | worktree | Hidden worktree; branch `feat/avi-sizes-designed-tasks` is clean and HEAD 7e65ab9 is contained in origin/release; health down, Redis DB 17, database mcritchie_studio_development_avi_sizes_designed_tasks:missing. | Removed with `bin/agent-worktree remove mcritchie-studio avi-sizes-designed-tasks --yes` during approved lifecycle cleanup. | removed 2026-07-01 |

<!-- agent-worktree remove 2026-07-01 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fade-shared-turn-token-duplicates` | worktree | Hidden worktree; branch `feat/fade-shared-turn-token-duplicates` is clean and HEAD 6a0aec2 is contained in origin/release; health down, Redis DB 11, database mcritchie_studio_development_fade_shared_turn_token_duplicates:missing. | Removed with `bin/agent-worktree remove mcritchie-studio fade-shared-turn-token-duplicates --yes` during approved lifecycle cleanup. | removed 2026-07-01 |

<!-- agent-worktree remove 2026-07-01 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fresh-tokens-accurate-cost` | worktree | Hidden worktree; branch `feat/fresh-tokens-accurate-cost` is clean and HEAD 643ac13 is contained in origin/release; health down, Redis DB 9, database mcritchie_studio_development_fresh_tokens_accurate_cost:ok. | Removed with `bin/agent-worktree remove mcritchie-studio fresh-tokens-accurate-cost --yes` during approved lifecycle cleanup. | removed 2026-07-01 |

<!-- agent-worktree remove 2026-07-01 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/modular-pr-review-sop` | worktree | Hidden worktree; branch `feat/modular-pr-review-sop` is clean and HEAD 24c2009 is contained in origin/release; health down, Redis DB 13, database mcritchie_studio_development_modular_pr_review_sop:missing. | Removed with `bin/agent-worktree remove mcritchie-studio modular-pr-review-sop --yes` during approved lifecycle cleanup. | removed 2026-07-01 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/add-task-merged-field` | worktree | Hidden worktree; branch `feat/add-task-merged-field` is clean and HEAD cd07f52 is contained in origin/release; health down, Redis DB 31, database mcritchie_studio_development_add_task_merged_field:ok. | Removed with `bin/agent-worktree remove mcritchie-studio add-task-merged-field --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/agent-span-grading-endpoint` | worktree | Hidden worktree; branch `feat/agent-span-grading-endpoint` is clean and HEAD 7fa9cb9 is contained in origin/release; health down, Redis DB 24, database mcritchie_studio_development_agent_span_grading_endpoint:missing. | Removed with `bin/agent-worktree remove mcritchie-studio agent-span-grading-endpoint --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/cleared-block-re-review-state` | worktree | Hidden worktree; branch `feat/cleared-block-re-review-state` is clean and HEAD 3d0ab58 is contained in origin/release; health down, Redis DB 29, database mcritchie_studio_development_cleared_block_re_review_state:ok. | Removed with `bin/agent-worktree remove mcritchie-studio cleared-block-re-review-state --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/consolidate-heartbeats-add-archive` | worktree | Hidden worktree; branch `feat/consolidate-heartbeats-add-archive` is clean and HEAD 0f3f973 is contained in origin/release; health up, Redis DB 12, database mcritchie_studio_development_consolidate_heartbeats_add_archive:ok. | Removed with `bin/agent-worktree remove mcritchie-studio consolidate-heartbeats-add-archive --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/correct-stale-ship-spec-header` | worktree | Hidden worktree; branch `feat/correct-stale-ship-spec-header` is clean and HEAD 7b29968 is contained in origin/release; health down, Redis DB 20, database mcritchie_studio_development_correct_stale_ship_spec_header:missing. | Removed with `bin/agent-worktree remove mcritchie-studio correct-stale-ship-spec-header --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/devops-card-2x2-grid` | worktree | Hidden worktree; branch `feat/devops-card-2x2-grid` is clean and HEAD f7bb1b9 is contained in origin/release; health up, Redis DB 17, database mcritchie_studio_development_devops_card_2x2_grid:ok. | Removed with `bin/agent-worktree remove mcritchie-studio devops-card-2x2-grid --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/distillation-pipeline-three-column-page` | worktree | Hidden worktree; branch `feat/distillation-pipeline-three-column-page` is clean and HEAD 16ab06b is contained in origin/release; health down, Redis DB 27, database mcritchie_studio_development_distillation_pipeline_thr_f98f20dd:ok. | Removed with `bin/agent-worktree remove mcritchie-studio distillation-pipeline-three-column-page --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/feed-banked-insights-forward` | worktree | Hidden worktree; branch `feat/feed-banked-insights-forward` is clean and HEAD 12e9d23 is contained in origin/release; health down, Redis DB 23, database mcritchie_studio_development_feed_banked_insights_forward:missing. | Removed with `bin/agent-worktree remove mcritchie-studio feed-banked-insights-forward --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/generate-insights-doc-from-bank` | worktree | Hidden worktree; branch `feat/generate-insights-doc-from-bank` is clean and HEAD 475d738 is contained in origin/release; health down, Redis DB 25, database mcritchie_studio_development_generate_insights_doc_from_bank:missing. | Removed with `bin/agent-worktree remove mcritchie-studio generate-insights-doc-from-bank --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/heartbeat-deployments-back-link` | worktree | Hidden worktree; branch `feat/heartbeat-deployments-back-link` is clean and HEAD bb713fd is contained in origin/release; health up, Redis DB 11, database mcritchie_studio_development_heartbeat_deployments_back_link:ok. | Removed with `bin/agent-worktree remove mcritchie-studio heartbeat-deployments-back-link --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/heartbeat-launcher-two-row-grid` | worktree | Hidden worktree; branch `feat/heartbeat-launcher-two-row-grid` is clean and HEAD 90354db is contained in origin/release; health down, Redis DB 9, database mcritchie_studio_development_heartbeat_launcher_two_row_grid:ok. | Removed with `bin/agent-worktree remove mcritchie-studio heartbeat-launcher-two-row-grid --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/make-grading-actions-public` | worktree | Hidden worktree; branch `feat/make-grading-actions-public` is clean and HEAD d55dfc1 is contained in origin/release; health down, Redis DB 26, database mcritchie_studio_development_make_grading_actions_public:missing. | Removed with `bin/agent-worktree remove mcritchie-studio make-grading-actions-public --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/redact-secrets-from-capture-hook` | worktree | Hidden worktree; branch `feat/redact-secrets-from-capture-hook` is clean and HEAD 9b98b37 is contained in origin/release; health down, Redis DB 13, database mcritchie_studio_development_redact_secrets_from_capture_hook:missing. | Removed with `bin/agent-worktree remove mcritchie-studio redact-secrets-from-capture-hook --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/reorder-heartbeat-act-order` | worktree | Hidden worktree; branch `feat/reorder-heartbeat-act-order` is clean and HEAD f703261 is contained in origin/release; health down, Redis DB 28, database mcritchie_studio_development_reorder_heartbeat_act_order:ok. | Removed with `bin/agent-worktree remove mcritchie-studio reorder-heartbeat-act-order --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/root-merge-gates-at-worktree` | worktree | Hidden worktree; branch `feat/root-merge-gates-at-worktree` is clean and HEAD e9604a4 is contained in origin/release; health down, Redis DB 18, database mcritchie_studio_development_root_merge_gates_at_worktree:missing. | Removed with `bin/agent-worktree remove mcritchie-studio root-merge-gates-at-worktree --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/scope-span-invariant-per-agent` | worktree | Hidden worktree; branch `feat/scope-span-invariant-per-agent` is clean and HEAD c424cec is contained in origin/release; health down, Redis DB 22, database mcritchie_studio_development_scope_span_invariant_per_agent:missing. | Removed with `bin/agent-worktree remove mcritchie-studio scope-span-invariant-per-agent --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-03 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/secure-learning-loop-grade-endpoints` | worktree | Hidden worktree; branch `feat/secure-learning-loop-grade-endpoints` is clean and HEAD 22c86c7 is contained in origin/release; health down, Redis DB 15, database mcritchie_studio_development_secure_learning_loop_grad_7d5b8bdc:missing. | Removed with `bin/agent-worktree remove mcritchie-studio secure-learning-loop-grade-endpoints --yes` during approved lifecycle cleanup. | removed 2026-07-03 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/add-key-method-and-summary` | worktree | Hidden worktree; branch `feat/add-key-method-and-summary` is clean and HEAD dde2da25 is contained in origin/release; health up, Redis DB 13, database mcritchie_studio_development_add_key_method_and_summary:ok. | Removed with `bin/agent-worktree remove mcritchie-studio add-key-method-and-summary --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/alex-links-on-deployments` | worktree | Hidden worktree; branch `feat/alex-links-on-deployments` is clean and HEAD 9c6b7efa is contained in origin/release; health down, Redis DB 15, database mcritchie_studio_development_alex_links_on_deployments:ok. | Removed with `bin/agent-worktree remove mcritchie-studio alex-links-on-deployments --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/document-heartbeat-session-launch` | worktree | Hidden worktree; branch `feat/document-heartbeat-session-launch` is clean and HEAD 18b26461 is contained in origin/release; health down, Redis DB 23, database mcritchie_studio_development_document_heartbeat_session_launch:missing. | Removed with `bin/agent-worktree remove mcritchie-studio document-heartbeat-session-launch --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/drop-qa-readonly-cleared-block-spec` | worktree | Hidden worktree; branch `feat/drop-qa-readonly-cleared-block-spec` is clean and HEAD 69f3f544 is contained in origin/release; health down, Redis DB 9, database mcritchie_studio_development_drop_qa_readonly_cleared__ec6fee27:missing. | Removed with `bin/agent-worktree remove mcritchie-studio drop-qa-readonly-cleared-block-spec --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/extract-shared-agent-api-client` | worktree | Hidden worktree; branch `feat/extract-shared-agent-api-client` is clean and HEAD 57458640 is contained in origin/release; health down, Redis DB 11, database mcritchie_studio_development_extract_shared_agent_api_client:missing. | Removed with `bin/agent-worktree remove mcritchie-studio extract-shared-agent-api-client --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-duplicate-sticky-headers` | worktree | Hidden worktree; branch `feat/fix-duplicate-sticky-headers` is clean and HEAD 6cc93159 is contained in origin/release; health up, Redis DB 24, database mcritchie_studio_development_fix_duplicate_sticky_headers:ok. | Removed with `bin/agent-worktree remove mcritchie-studio fix-duplicate-sticky-headers --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/move-release-assembly-to-steffon` | worktree | Hidden worktree; branch `feat/move-release-assembly-to-steffon` is clean and HEAD 976ddda9 is contained in origin/release; health down, Redis DB 12, database mcritchie_studio_development_move_release_assembly_to_steffon:missing. | Removed with `bin/agent-worktree remove mcritchie-studio move-release-assembly-to-steffon --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/rename-propagate-insights-act` | worktree | Hidden worktree; branch `feat/rename-propagate-insights-act` is clean and HEAD 6bc9b176 is contained in origin/release; health up, Redis DB 32, database mcritchie_studio_development_rename_propagate_insights_act:ok. | Removed with `bin/agent-worktree remove mcritchie-studio rename-propagate-insights-act --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/tidy-two-review-nits` | worktree | Hidden worktree; branch `feat/tidy-two-review-nits` is clean and HEAD 94251bcf is contained in origin/release; health down, Redis DB 22, database mcritchie_studio_development_tidy_two_review_nits:missing. | Removed with `bin/agent-worktree remove mcritchie-studio tidy-two-review-nits --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/wire-bank-to-session-bridge` | worktree | Hidden worktree; branch `feat/wire-bank-to-session-bridge` is clean and HEAD e9c7b3b3 is contained in origin/release; health down, Redis DB 18, database mcritchie_studio_development_wire_bank_to_session_bridge:missing. | Removed with `bin/agent-worktree remove mcritchie-studio wire-bank-to-session-bridge --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/agent-file-links` | worktree | Hidden worktree; branch `feat/agent-file-links` is clean and HEAD 52c81497 is contained in origin/release; health up, Redis DB 28, database mcritchie_studio_development_agent_file_links:ok. | Removed with `bin/agent-worktree remove mcritchie-studio agent-file-links --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/block-mining-insight-lever` | worktree | Hidden worktree; branch `feat/block-mining-insight-lever` is clean and HEAD 80f38086 is contained in origin/release; health down, Redis DB 20, database mcritchie_studio_development_block_mining_insight_lever:missing. | Removed with `bin/agent-worktree remove mcritchie-studio block-mining-insight-lever --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/fix-pr-review-card-captions` | worktree | Hidden worktree; branch `feat/fix-pr-review-card-captions` is clean and HEAD 013e04e9 is contained in origin/release; health down, Redis DB 13, database mcritchie_studio_development_fix_pr_review_card_captions:ok. | Removed with `bin/agent-worktree remove mcritchie-studio fix-pr-review-card-captions --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/name-install-agent-docs-owner` | worktree | Hidden worktree; branch `feat/name-install-agent-docs-owner` is clean and HEAD 4eabae6d is contained in origin/release; health down, Redis DB 15, database mcritchie_studio_development_name_install_agent_docs_owner:missing. | Removed with `bin/agent-worktree remove mcritchie-studio name-install-agent-docs-owner --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/pr-review-launcher-routing` | worktree | Hidden worktree; branch `feat/pr-review-launcher-routing` is clean and HEAD b9ed6d71 is contained in origin/release; health down, Redis DB 18, database mcritchie_studio_development_pr_review_launcher_routing:missing. | Removed with `bin/agent-worktree remove mcritchie-studio pr-review-launcher-routing --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/refresh-adapter-sweep-wording` | worktree | Hidden worktree; branch `feat/refresh-adapter-sweep-wording` is clean and HEAD b8f3184f is contained in origin/release; health down, Redis DB 26, database mcritchie_studio_development_refresh_adapter_sweep_wording:ok. | Removed with `bin/agent-worktree remove mcritchie-studio refresh-adapter-sweep-wording --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/register-qa-test-commands` | worktree | Hidden worktree; branch `feat/register-qa-test-commands` is clean and HEAD b9441440 is contained in origin/release; health down, Redis DB 25, database mcritchie_studio_development_register_qa_test_commands:missing. | Removed with `bin/agent-worktree remove mcritchie-studio register-qa-test-commands --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/release-stage-timestamp-handoff` | worktree | Hidden worktree; branch `feat/release-stage-timestamp-handoff` is clean and HEAD 1d9ec99d is contained in origin/release; health up, Redis DB 12, database mcritchie_studio_development_release_stage_timestamp_handoff:ok. | Removed with `bin/agent-worktree remove mcritchie-studio release-stage-timestamp-handoff --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/rewrite-retired-launcher-spec` | worktree | Hidden worktree; branch `feat/rewrite-retired-launcher-spec` is clean and HEAD 3b101a73 is contained in origin/release; health up, Redis DB 23, database mcritchie_studio_development_rewrite_retired_launcher_spec:ok. | Removed with `bin/agent-worktree remove mcritchie-studio rewrite-retired-launcher-spec --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/shiny-pokemon-mascot-avatars` | worktree | Hidden worktree; branch `feat/shiny-pokemon-mascot-avatars` is clean and HEAD 4716343b is contained in origin/release; health up, Redis DB 9, database mcritchie_studio_development_shiny_pokemon_mascot_avatars:ok. | Removed with `bin/agent-worktree remove mcritchie-studio shiny-pokemon-mascot-avatars --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/sweep-mission-doc-wording` | worktree | Hidden worktree; branch `feat/sweep-mission-doc-wording` is clean and HEAD f1b2cf3a is contained in origin/release; health down, Redis DB 11, database mcritchie_studio_development_sweep_mission_doc_wording:missing. | Removed with `bin/agent-worktree remove mcritchie-studio sweep-mission-doc-wording --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/sweep-remaining-doc-stragglers` | worktree | Hidden worktree; branch `feat/sweep-remaining-doc-stragglers` is clean and HEAD 4d89ff74 is contained in origin/release; health down, Redis DB 24, database mcritchie_studio_development_sweep_remaining_doc_stragglers:ok. | Removed with `bin/agent-worktree remove mcritchie-studio sweep-remaining-doc-stragglers --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/sweep-retired-sop-names` | worktree | Hidden worktree; branch `feat/sweep-retired-sop-names` is clean and HEAD 692035ed is contained in origin/release; health down, Redis DB 22, database mcritchie_studio_development_sweep_retired_sop_names:missing. | Removed with `bin/agent-worktree remove mcritchie-studio sweep-retired-sop-names --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/update-release-cli-copy` | worktree | Hidden worktree; branch `feat/update-release-cli-copy` is clean and HEAD 3c4ce0a5 is contained in origin/release; health down, Redis DB 29, database mcritchie_studio_development_update_release_cli_copy:missing. | Removed with `bin/agent-worktree remove mcritchie-studio update-release-cli-copy --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/add-johto-pokemon-roster` | worktree | Hidden worktree; branch `feat/add-johto-pokemon-roster` is clean and HEAD 16b2faf1 is contained in origin/release; health down, Redis DB 36, database mcritchie_studio_development_add_johto_pokemon_roster:ok. | Removed with `bin/agent-worktree remove mcritchie-studio add-johto-pokemon-roster --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/base-level-spawn-pool` | worktree | Hidden worktree; branch `feat/base-level-spawn-pool` is clean and HEAD da12ec64 is contained in origin/release; health down, Redis DB 11, database mcritchie_studio_development_base_level_spawn_pool:ok. | Removed with `bin/agent-worktree remove mcritchie-studio base-level-spawn-pool --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/compact-heartbeat-commands` | worktree | Hidden worktree; branch `feat/compact-heartbeat-commands` is clean and HEAD 1c7b766e is contained in origin/release; health up, Redis DB 33, database mcritchie_studio_development_compact_heartbeat_commands:ok. | Removed with `bin/agent-worktree remove mcritchie-studio compact-heartbeat-commands --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/completed-stage-ago-time` | worktree | Hidden worktree; branch `feat/completed-stage-ago-time` is clean and HEAD 0cc28846 is contained in origin/release; health down, Redis DB 9, database mcritchie_studio_development_completed_stage_ago_time:ok. | Removed with `bin/agent-worktree remove mcritchie-studio completed-stage-ago-time --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/inline-span-badges` | worktree | Hidden worktree; branch `feat/inline-span-badges` is clean and HEAD 928ed90b is contained in origin/release; health up, Redis DB 13, database mcritchie_studio_development_inline_span_badges:ok. | Removed with `bin/agent-worktree remove mcritchie-studio inline-span-badges --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/pokemon-roster-shiny-evolutions` | worktree | Hidden worktree; branch `feat/pokemon-roster-shiny-evolutions` is clean and HEAD 7ba7f7b2 is contained in origin/release; health up, Redis DB 12, database mcritchie_studio_development_pokemon_roster_shiny_evolutions:ok. | Removed with `bin/agent-worktree remove mcritchie-studio pokemon-roster-shiny-evolutions --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/remove-deployment-copy-buttons` | worktree | Hidden worktree; branch `feat/remove-deployment-copy-buttons` is clean and HEAD 35c3d405 is contained in origin/release; health up, Redis DB 34, database mcritchie_studio_development_remove_deployment_copy_buttons:ok. | Removed with `bin/agent-worktree remove mcritchie-studio remove-deployment-copy-buttons --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/rename-review-supervisor-script` | worktree | Hidden worktree; branch `feat/rename-review-supervisor-script` is clean and HEAD 9e8ff5a8 is contained in origin/release; health down, Redis DB 31, database mcritchie_studio_development_rename_review_supervisor_script:missing. | Removed with `bin/agent-worktree remove mcritchie-studio rename-review-supervisor-script --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-04 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/task-mascot-evolution-gates` | worktree | Hidden worktree; branch `feat/task-mascot-evolution-gates` is clean and HEAD d5039813 is contained in origin/release; health up, Redis DB 15, database mcritchie_studio_development_task_mascot_evolution_gates:ok. | Removed with `bin/agent-worktree remove mcritchie-studio task-mascot-evolution-gates --yes` during approved lifecycle cleanup. | removed 2026-07-04 |

<!-- agent-worktree remove 2026-07-05 -->
| `/Users/alex/projects/mcritchie-studio/.worktrees/rename-heartbeat-link-to-outcomes` | worktree | Hidden worktree; branch `feat/rename-heartbeat-link-to-outcomes` is clean and HEAD 024b70dd is contained in origin/release; health down, Redis DB 20, database mcritchie_studio_development_rename_heartbeat_link_to_outcomes:ok. | Removed with `bin/agent-worktree remove mcritchie-studio rename-heartbeat-link-to-outcomes --yes` during approved lifecycle cleanup. | removed 2026-07-05 |
