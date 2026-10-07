# Guard catalog — guards to success

**Status: proposed, awaiting Alex's decision.** Piece 1h of the
`platform-audit-refactors` epic. Alex's rule (2026-10-05): prefer designs that
succeed by construction over guards. Nothing on this page changes a guard; each
row proposes one disposition for Alex to accept or overrule.

A **guard** here is any check that refuses: an `abort!`, `die!`, `raise` or
nonzero exit that stops progress, a server-side 4xx or validation, a test that
pins prose, a line or a count, or a `warn_note` advisory. Read on `accepted` at
5b55c427 (2026-10-06). The tooling holds 1,738 lines in `bin/` that match
`abort!|die!|refus|REFUS|warn_note`; the docs hold 1,043.

## Dispositions

- **DELETE**: the mechanism it protects is gone, the check duplicates another,
  or it refuses a state that harms nothing.
- **BY CONSTRUCTION**: replace the check with a design that cannot produce the
  bad state; the row names the construction.
- **KEEP**: a precondition in the real world that is cheap to check, or an
  irreversible write that needs one read first.

The principle carries over from [`devops-v3-design.md`](devops-v3-design.md)
section 7: a guard that compares two copies of one fact goes when the copy goes;
a guard on a precondition in the world stays.

## Totals

| Group | Guards | Delete | By construction | Keep |
|---|---|---|---|---|
| 1. Certs, evidence and the CI gate | 64 | 1 | 10 | 53 |
| 2. Definition of Ready | 40 | 2 | 7 | 31 |
| 3. Ship, task begin and claims | 62 | 5 | 6 | 51 |
| 4. Session preflight and installed docs | 21 | 4 | 5 | 12 |
| 5. Desks, identity and hygiene | 47 | 4 | 3 | 40 |
| 6. Review flow | 33 | 1 | 2 | 30 |
| 7. Release | 102 | 0 | 13 | 89 |
| 8. Docs and citation guards | 42 | 9 | 24 | 9 |
| 9. Registry guards and ratchets | 34 | 1 | 15 | 18 |
| 10. App validations and API refusals | 49 | 2 | 8 | 39 |
| **Total** | **494** | **29** | **93** | **372** |

Fires: no store counts refusals. Every `bin/dor-check` verdict writes a
`GateRun` row, and `/Users/alex/projects/.agents/worktree-registry.json` records
each withheld desk's reason; everything else is unmeasured unless a code comment
records an incident, and those counts are history, not a rate. Advisories that
never block sit in KEEP.

## The ten decisions worth making first

| # | Guard | Today | Proposal | Evidence |
|---|---|---|---|---|
| 1 | `bin/session-preflight#install_docs_check` and `bin/install-agent-docs` check | Fails the preflight, and so `bin/task begin` step 5/5 after the desk is claimed, when the installed entry docs differ from the desk's tree; the installer's own text says the drift is expected and "NOT yours to fix" | BY CONSTRUCTION: a desk measures nothing it cannot fix. The check compares the installed docs with the tree the last ship published, and the ship publishes | Worked example A; the plan's builder note of 2026-10-05; three agents read the failure on 2026-09-07 |
| 2 | `docs_with_guards_diff` claim in `bin/dor-check` (`bin/lib/code_diff.rb#non_guard_code_files`) | The `docs` shape refuses any file that is not prose or a `test/docs/*_test.rb`, including a `test/lib` guard edit and a comment-only `.rb` edit | BY CONSTRUCTION: classify by hunk (a Ripper token stream with comments dropped equals the base's) and admit guard tests by name under any `test/` directory | Tonight `clean-up-sop-cut-down` split into two PRs (1866 prose, 1867 a `test/lib` label edit) and paid a second review |
| 3 | Citation lanes 1, 3, 4 and 5 in `test/docs/citation_resolution_guard_test.rb` | Lane 3 caps `path:line` citations at 55 and lane 5 caps unanchored ones at 49; lanes 1 and 4 chase line rot | BY CONSTRUCTION: convert the 55 to seams, set the ceiling to 0, then DELETE lanes 1, 4 and 5 and their grammar self-tests. Lane 2 (a seam must name a definition) stays | Tonight `regenerate-rails-lane-timings` repointed about 30 citations to a deleted file, and `turf-draws-its-login-bounce` re-applied a one-line shift by hand |
| 4 | The stale-entry timings test in `test/lib/test_shard_test.rb` (deleted by `guards-registries-and-ratchets`) | Reds CI when `test/timings.yml` weighs a file the lane no longer runs | DELETE: `bin/measure-test-timings` already slices to the lane and warns on dropped files, and the test's own comment says a stale line "costs nothing at run time" | Added 2026-10-06 (c3ba0318) after `regenerate-rails-lane-timings` bounced on a line for the file PR 1886 deleted |
| 5 | NO-SIGNAL arm of `bin/dor-check` `required_evidence: [control]` | Refuses a test-only claim whose control replay comes back NO-SIGNAL with no `[control]` sentence; the message says "it is not refusing your change" | BY CONSTRUCTION: `bin/control-check` asks for the sentence when it stamps NO-SIGNAL and writes it into the stamp, so the state "NO-SIGNAL without a sentence" never exists. The "names no file from this diff" substring check folds in | Tonight's NO-SIGNAL path; the code comment reads "THE VERDICT NEVER REFUSES" |
| 6 | "task is blocked" error in `bin/session-preflight` | A rework block leaves the task on `building` with `blocked_at` set; preflight errors on it, so the builder fixing the rework fails `bin/task begin`, and `bin/task` has no unblock | BY CONSTRUCTION: `begin` on a blocked `building` task is the answer to the block and clears it (`Task#unblock!`); preflight never fails after the claim | The comment above the check calls it a "warning"; the code adds an error |
| 7 | Contract arithmetic in `config/e2e_lane.yml` (`E2eExecutedSet#count_failures` and the e2e quarantine ratchet) | `total_specs` and `executed` are hand-written counts every spec add must bump | BY CONSTRUCTION: compute both from the spec files at run time; keep only `quarantined` and the ceiling ratchet | 86 commits touch the file, 58 since 2026-09-06 |
| 8 | Turf settlement winner limit (`turf-monster/app/models/contest.rb#settle_onchain!`) | No guard yet: a contest with more paid entries than one settle transaction holds fails at send, and the rescue logs it | BY CONSTRUCTION: formats that always fit one transaction, instead of a refusal at grade time | Worked example B; plan piece 0c |
| 9 | Guards on retired mechanisms and derived stamps | The cert-database reaper, the legacy build-lease hold, `cert_route` validation, the orphan `doc_only_diff` arm, the review pulse, and the `pr_url` and `merged` write-and-read-back checks | DELETE: each protects a mechanism v3 retired or a fact the board now derives from GitHub | Groups 1, 3, 5 and 6 below |
| 10 | Registries kept in copies | The SOP table, its `claude.md` list and Start Here labels; `config/apps.yml` against three registries; `Task::SOUL_ROSTER` against the seed; `bin/task` `BLOCK_KINDS` against the model's | BY CONSTRUCTION: generate each copy from one source, then delete the parity test. The model holds `Task::BLOCK_KINDS` and validates nothing, so the server check comes first | Group 9 below |

## Worked example A: a desk measures nothing it cannot fix

`bin/task begin` cuts a desk from `origin/accepted`, binds it, claims the task,
then runs `bin/session-preflight`. Its `install_docs_check` runs the installer's
`check`, which compares `/Users/alex/projects/AGENTS.md`, `CLAUDE.md` and the
installed skills with the desk's own sources. Those copies come from the last
production ship (`bin/release.rb#sync_agent_docs`), so any docs merge since then
makes them differ. The installer prints that the drift is expected and that the
owner is the next ship; the preflight still adds an error, exits 1, and begin
stops at step 5/5 after the claim. Today the copies match, so the check passed on
this desk; it fails on the next desk cut after a docs merge.

The construction: the preflight compares the installed copies with the tree the
last ship published (the fixed-path tooling already names that SHA), and the only
writer is the ship. Nothing a builder can do changes the answer, so nothing a
builder runs asks the question.

## Worked example B: a contest that always fits

One settle transaction holds five paid entries on vault v0.25 and four on v0.26
(a 1,232-byte limit). Today `Contest#settle_onchain!` builds one transaction for
every paid entry and its rescue logs the failure, so an oversized contest strands
at settlement. The guard first proposed refuses at grade time. The construction is
piece 0c: every format pays at most four entries, the last paid tie breaks to the
earliest entry, and the payout table snapshots at creation, so no contest can
reach grading with a settlement that does not fit.

## 1. Certs, evidence and the CI gate (64)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| `bin/control-check` dirty-tree, restore-did-not-land and harness-did-not-restore `die`s | Replaying in the live desk → a restore that clobbers edits or stamps the wrong tree | The `sed -i ''` lesson · unmeasured | 3 | BY CONSTRUCTION: replay in a throwaway worktree cut at the base; nothing needs restoring · applied: `guards-certs-dor-and-ship` (`bin/control-check` replays in a throwaway worktree at the merge base) |
| `bin/control-check` usage, repo, base, empty diff, fingerprint, prepare, blob, board read, write and read-back | Bad input or a lost stamp | 2026-08-31 docs ledger; stale snapshot · unmeasured | 11 | KEEP · kept: `guards-certs-dor-and-ship` |
| `bin/dor-check` control: executed stamp required; `[control]` line required | An evidence-free test-only claim | 2026-08-10, 2026-08-11 · about 79% of test-only history eligible | 2 | KEEP · kept: `guards-certs-dor-and-ship` |
| `bin/dor-check` control: NO-SIGNAL without a sentence; "names no file" | See decision 5 | · unmeasured | 2 | BY CONSTRUCTION (decision 5) · applied: `guards-certs-dor-and-ship` (`bin/control-check --why` writes the sentence into the stamp, and the hand `[control]` line naming the diff's files) |
| `bin/fast-check` wrong root (`TaskTree.refusal`), desk DB (`DeskGuard.refusal`), prepare and lane exits | A false pre-flight green; a shared test DB | 2026-08-21 (41-minute prepare) · gates nothing | 6 | KEEP: the optional pre-flight's own verdict · kept: `guards-certs-dor-and-ship` |
| `bin/lib/rails_executed_set.rb` commit skew ("CHECKOUT RACE, not a coverage hole") | Receipts from a commit other than the tree's → stays red on a state its message calls harmless | Run 32495361932, PR 979 | 1 | BY CONSTRUCTION: gate and shards check out `github.sha` · applied: `guards-certs-dor-and-ship` (`ref: github.sha` on the plan, shards and gate; pinned by `test/lib/rails_lane_checkout_pin_test.rb`) |
| `bin/rails-executed-set-check` and `RailsExecutedSet` (no receipts, missing shard, duplicates, count, attribution, executed nothing, unowned file, zero tests, skip ceiling, usage, empty contract) | A lane that silently covers less | 2026-08-21 · unmeasured | 12 | KEEP · kept: `guards-certs-dor-and-ship` |
| `E2eExecutedSet#count_failures` | Executed count differs from a hand count | PR 543, three rounds | 1 | BY CONSTRUCTION (decision 7) · applied: `guards-registries-and-ratchets` (row 9 e2e contract arithmetic) |
| `bin/e2e-executed-set-check` and `E2eExecutedSet` (usage, no reports, parse, shape, completeness, skips, quarantine leak) | A dropped shard or skipped spec read as green | PR 543 · three kills | 7 | KEEP · kept: `guards-certs-dor-and-ship` |
| `bin/lib/ci_gate.rb#CiGate` builder-side `:pending` and `:none` | Exit 1 while CI is still running; "nothing about the tree is refused" | /tasks/dor-reads-settled-ci-verdict · rare after `CiWait` | 2 | BY CONSTRUCTION: `bin/submit` calls the gate only after `CiWait` settles · applied: `guards-certs-dor-and-ship` (`bin/submit` stops at 6/8 on a CI still running or never reported) |
| `CiStatus.validate_cert_route!` | A misspelled route that prints retired cert text | PR 1235 · 0 | 1 | DELETE with `cert_route` · applied: `guards-certs-dor-and-ship` (`release_grain:`, a boolean keyword) |
| `bin/lib/stacked_pr.rb#StackedPr` blank `repo_scope` | A false `:not_stacked` read from the cwd's repo | /tasks/review-refuses-unread-base | 1 | BY CONSTRUCTION: `repo_scope:` becomes a required keyword · applied in part: `guards-certs-dor-and-ship` (`repo_scope:` is required); kept: the blank-value refusal, because `bin/pr-review` derives the scope from a URL regex that can still miss |
| `CiGate` red, conflicted, ci-less, review-side pending, closed, unverified, unreadable, no PR, unclassified; `bin/dor-check` behind-base and `#stale_green_refusal`; `StackedPr` unread base, empty branch, unreadable probe, stacked | Merging on red, unknown or untested CI; dragging a parent PR | PR 509 stall; PR 1258; turf 701 on 624 | 15 | KEEP: the single CI verdict. `ci_status.rb`'s header still describes the retired cert remedy · kept: `guards-certs-dor-and-ship` |

## 2. Definition of Ready (40)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| `bin/dor-check#release_owned_gem_files` | A PR that edits a gem version file → colliding versions | Four studio-engine PRs, 2026-08-10 | 1 | BY CONSTRUCTION: `bin/release prepare` writes the allocated version over whatever the PR set · kept against the verdict: `guards-certs-dor-and-ship`. `Release::GemVersion.allocation` deliberately honours a version already past the tag (the self-healing re-run and the operator's documented hand-set remedy in `bin/release.rb#publish_gem`), so writing the allocated version over it would override the operator or burn a number; this refusal is what keeps a PR-set version out |
| `gem_constraint_violations` in `bin/dor-check` (deleted) | A Gemfile the lock cannot satisfy | mcritchie 157 | 1 | DELETE: CI's frozen bundle install fails first, and the gate reads CI · applied: `guards-certs-dor-and-ship` |
| `missing_tiers` | A shape whose `[tier]` tag is untyped; a tag is free text | v3 section 7 · 216 + 14 refusals | 1 | BY CONSTRUCTION: tiers come from CI's executed-set receipts · kept against the verdict: `guards-certs-dor-and-ship`. CI runs every tier on every PR, so its executed-set receipts cannot say which tiers this PR wrote tests at; the construction needs a design (map the diff's test files to tiers, then confirm CI ran them) and its own task |
| `docs_with_guards_diff` claim | See decision 2 | PR 1172 | 1 | BY CONSTRUCTION (decision 2) · applied: `guards-certs-dor-and-ship` (`bin/lib/ruby_comment_diff.rb`; `*_guard_test.rb` under any `test/` directory) |
| `doc_only_diff` arm | No shape declares it | 2026-09-02 · 0 | 1 | DELETE · applied: `guards-certs-dor-and-ship` |
| Unclassified `claimable_when` | A rule dor-check does not implement | · unmeasured | 1 | BY CONSTRUCTION: a load-time schema check on `config/feature_shapes.yml` · applied: `guards-certs-dor-and-ship` (`CLAIM_RULES`, checked when the config loads) |
| `data_changed_files` without `post_deploy_cmd` | A schema-only migration with the field blank, until "none" is typed | pokemon:seed examples | 1 | BY CONSTRUCTION: the field defaults to `none` when the diff touches only `db/migrate`, which the release phase runs · applied: `guards-certs-dor-and-ship` |
| `bare_full_suite_seed?` in `bin/dor-check` (moved to the Task model) | `db:seed` as the post-deploy command | One near-miss | 1 | BY CONSTRUCTION: the Task model rejects it on write, so the gate never meets it · applied: `guards-certs-dor-and-ship` (`Task#post_deploy_cmd_is_not_a_bare_seed`) |
| `ReviewTreeGuard.head_assessment` `:mismatch` | Local ref differs from the PR head; "can only ever be a FALSE REFUSAL" on an unfetched desk | turf 519 | 1 | BY CONSTRUCTION: fetch the PR head before the verdict · applied: `guards-certs-dor-and-ship` (a leftover mismatch is a suggestion) |
| Plumbing (`--gate`, secret, API, task load, file), exempt-path indeterminate reads (5), shape blank or unknown, required metadata, `test_only_diff`, guard-tests-with-no-prose, partial and blind claim reads, PR-read alert, browser program without a spec, `Dor::Checks::MigrationCollision`, check-crash fail-closed | Grading a tree or PR nobody read; an ungated code diff; a release-phase crash | 2026-08-08; three DuplicateMigrationNameError crashes 2026-08-13/14 | 21 | KEEP. The guard-tests message still names the retired full-suite cert · kept: `guards-certs-dor-and-ship` |
| Advisories: no PR head, base unobservable, base moved, browser bypass, browser-evidence hole, client bindings, present-surface edits, fragile runner form, submit-side PR read, `PrOverlap.lines` | Nothing blocks | · | 10 | KEEP · kept: `guards-certs-dor-and-ship` |

## 3. Ship, task begin and claims (62)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| `bin/submit` build-stage seam | A task still on `designed` | · | 1 | BY CONSTRUCTION: ship moves it to `building` itself · applied: `guards-certs-dor-and-ship` |
| `bin/submit` empty commit message | No `-m` and no title; every task has a title | · | 1 | DELETE · applied: `guards-certs-dor-and-ship` |
| `bin/submit` `pr_url` write, stage read-back, `pr_url` read-back | A lost board write | Silent-save incident; v3 4c-i derives `pr_url` | 3 | DELETE: `bin/task move` verifies the stage and the board derives the URL · applied: `guards-certs-dor-and-ship` (a failed `--pr-url` write is a note) |
| `bin/lib/ship_wait.rb#ShipWait` failed verdict | A run with no success line; an already-reviewed task exits 0 without one and reads as failed | · | 1 | BY CONSTRUCTION: ship prints one terminal line on every exit path · applied: `guards-certs-dor-and-ship` (`stage: <stage> (past the submitted seam)` and `(not submitted)`) |
| `verify_merged_persisted!` in `bin/task` (deleted) | A dropped `merged` stamp | 2026-07-21, nine tasks · `MERGED_NOT_NEEDED_NOTICE` | 1 | DELETE: `merged` is derived · applied: `guards-certs-dor-and-ship` (`StampConfirmation` goes with it) |
| `validate_agent_slug!` (now `bin/task#normalize_agent_slug!`), `bin/task#refuse_comma_list!` | `--agent Steffon`; `--repo a,b` | Four silent drops; 1,117 joined tags | 2 | BY CONSTRUCTION: normalize case and split commas; refuse only a slug no soul matches · applied: `guards-certs-dor-and-ship` (`--pr-url-for a,b=<url>` still refuses: one url cannot split) |
| `bin/task#refuse_inert_create_flags!` on an existing task | Re-running the documented begin line with `--shape` | · | 1 | BY CONSTRUCTION: forward the flags to `update`, which the message already names · applied: `guards-certs-dor-and-ship` |
| `bin/task#begin_step!` 5/5 preflight | Any preflight error, after the claim | begin-preflight-wrong-root | 1 | BY CONSTRUCTION: preflight runs before the claim, and after it reports only · applied: `guards-preflight-and-desks` (the preflight runs before the claim and refuses it only when it cannot describe the desk, exit 2; findings, exit 1, are a report) |
| `bin/submit` usage, task read, `DeskClaim.blocking_on_disk`, wrong tree, wrong branch, commit, lease push, push, `gh` calls, unparsed URL, `MigrationCollision.blocking?`, dor-check, move; advisories (overlap, unattributed commit, red pre-flight, blind CI read, unread PR set); `bin/submit-wait` usage, already running, no log, timeout | Data loss, a foreign push, a red or blind handoff | 2026-07-29; three collisions on 2026-08-13/14 | 22 | KEEP · kept: `guards-certs-dor-and-ship` |
| `bin/task` grammar, slug shape, secret, API, door 1 inert flags, begin resume and stage, claim gates (begin, move, archive holder, open PR), step aborts, missing desk, abandonment and move read-backs, fix-forward read-back, bounce ledger and breaker (with `--breaker-ack`), block flags, usage audit, wait usage, `TaskBoard` and `BoardRead` strict reads, `bin/lib/cli_arg_guard.rb#CliArgGuard` (shared by about a dozen scripts), `TaskPrSet` staged merge; advisories (identity, orphan PRs, token hint) | A phantom repo, a claim over a dirty desk, an unread board read as empty | 2026-08-29; 2026-08-31 ledger loss; 2026-09-01 engine 245 | 29 | KEEP · kept: `guards-certs-dor-and-ship` |

## 4. Session preflight and installed docs (21)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| `bin/session-preflight#install_docs_check`; the installer's `check` exit | See decision 1 | 2026-09-07 · three agents in one night | 2 | BY CONSTRUCTION (worked example A) · applied: `guards-preflight-and-desks` (`check` reads the tree the fixed path names; the preflight prints it as information) |
| "task is blocked" | See decision 6 | · | 1 | BY CONSTRUCTION (decision 6) · applied: `guards-preflight-and-desks` (`PATCH /api/v1/tasks/:slug/unblock`, called by `begin`; rework blocks only, never an `Escalated:` block, which answer 409; each clear writes an audit Activity naming `by`) |
| `bin/session-preflight#stale_scan` | Stale words anywhere in the base docs, not the diff | · | 1 | BY CONSTRUCTION: scan only changed files · applied: `guards-preflight-and-desks` |
| Shape missing, unknown or short of metadata | Learned after the claim | · | 1 | BY CONSTRUCTION: `begin` validates on create · applied: `guards-preflight-and-desks` (`local_url` is left to the build) |
| "behind base; rebase" | Every resumed desk, since `accepted` moves constantly; no gate needs a rebase and CI tests the merge ref | · | 1 | DELETE · applied: `guards-preflight-and-desks` |
| `gh` auth STALE | `begin` never calls `gh`; `bin/submit` mints and retries | · | 1 | DELETE · applied: `guards-preflight-and-desks` |
| `BLOCKED` in `BAD_MERGE_STATES` | The normal state of a PR awaiting review | · | 1 | DELETE that member · applied: `guards-preflight-and-desks` |
| Duplicate migration | At begin it compares the base with itself; ship runs the real check | · | 1 | DELETE · applied: `guards-preflight-and-desks` |
| Usage and load, wrong checkout, CI-less, failed checks; installer help, arguments, mode, missing source, sandbox, Codex hooks; advisories (fetch ladder, dirty, overlap) | Describing the wrong tree; a help probe publishing globally | begin-preflight-wrong-root | 12 | KEEP · kept: `guards-preflight-and-desks` (a desk the preflight cannot describe exits 2) |

## 5. Desks, identity and hygiene (47)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| `bin/agent-worktree#claim_hold` lease branch | A live legacy lease; "nothing writes these leases" | desk-is-the-build-claim | 1 | DELETE (the board-unreadable hold stays) · applied: `guards-preflight-and-desks` |
| `bin/agent-worktree finish` blockers and `gh` aborts (`run_finish`, deleted) | The old handoff; `bin/submit` replaces it and only a `bin/qa-intake` hint names it | · | 2 | DELETE with the subcommand; repoint the hint · applied: `guards-preflight-and-desks` (`finish` still parses, does nothing, and names `bin/submit-wait`) |
| `bin/reap-cert-databases` and the `test/test_helper.rb` sweep (`CertDatabaseReaper`) | Dropping a non-cert database; only tests register cert databases now | "once bricked every release" · nothing to reap | 1 | DELETE · applied: `guards-preflight-and-desks` |
| `bin/agent-worktree#ignored_work_hold` | Reclaiming a desk whose gitignored files changed | 2026-09-26 · holds 12 of 27 desks today, on `test/dummy/public`, `playwright/.auth`, `Gemfile.lock`, `config/master.key` | 1 | BY CONSTRUCTION: the desk records its gitignored hashes at cut and the hold compares only hand-written paths, so regenerable files never hold · applied: `guards-preflight-and-desks` |
| `bin/agent-worktree#refuse_unrecorded_teardown!` | A teardown with no ledger row; a board outage blocks every teardown | 166 stranded rows | 1 | BY CONSTRUCTION: queue the record locally and post it when the board answers · applied: `guards-preflight-and-desks` (a board that answers with a refusal still refuses) |
| `bin/devops-reconcile` armed-state read | Warns on every run outside the hub (relative path) | 2026-09-23 | 1 | BY CONSTRUCTION: build the path with `BinHelpers.bin_for` · applied: `guards-preflight-and-desks` |
| `bin/agent-worktree` usage, app, slug, own stack, config, ports, stack health, missing desk, ambiguous desk, primary checkout, remove blockers, teardown leak, reclaim holds, managed root, discovered git, orphan-DB sweep, desk DB proof, restore-primary, Redis, registry write; `DeskClaim.blocking`; `DeskGuard`; `bin/ledger-guard` (2); advisories (2) | Destroying a live desk or a shared database | 512 databases 2026-08-25; one live desk destroyed | 26 | KEEP · kept: `guards-preflight-and-desks` |
| `ActingIdentity.check`, blank-token message, `GhIdentity.resolve`, `SessionIdentity` spare-process | Merging as Alex's account | 2026-08-29, two merges | 4 | KEEP. With no session the claim gates switch off quietly · kept: `guards-preflight-and-desks` |
| `BranchPrune` and `MarkerPrune` fail-closed reads, skip and keep rules, lease push, lane; `bin/clean-artifacts` argument guard; log-cap advisory; `bin/devops-reconcile` usage and board read; `bin/atomic-event` arguments and notes | Deleting a live branch or session | 2026-08-31 | 10 | KEEP. The `stamp-lost` heal goes with decision 9 · kept: `guards-preflight-and-desks` |

## 6. Review flow (33)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| `bin/lib/review_worker_pulse.rb#ReviewWorkerPulse` silent arm | Renewing a dead reviewer's lease; `renew_loop` already ends it at the same 12,275 s | 2026-09-22 | 1 | DELETE · applied: `guards-review-and-release` (the renew-loop's cap is the one brake; `status` still prints the pulse) |
| `ReviewerSelectSkip.message` | Picks a remedy by matching another file's refusal wording | · | 1 | BY CONSTRUCTION: each exit-10 arm carries its own code · applied: `guards-review-and-release` (a `skip_code` line on stdout under `--json`; the exit status stays 10) |
| `ReviewClaimCli` claim-next skip on board-ingested CI | The pop reads ingested CI, dor-check reads live `gh`, and they disagree | turf 407 | 1 | BY CONSTRUCTION: both read the ingested webhook verdict · kept against the verdict: `guards-review-and-release`. The live `gh` read in `bin/dor-check --gate-role review` is the read before a merge into `accepted`; moving it onto the board's ingested copy is a change to a merge guard, which this card keeps |
| `bin/pr-review` options and picks; `bin/reviewer-select` held, self-review, author-named-nobody, `none` contradicted or unverified, unknown authors, author seated, plumbing; merge with no PR; CI block, defer and warn; breaker escalation; claim skip; fix-forward warning; `ReviewClaimCli` arguments, acquire, renew, release; base report; `ReviewHop` and `bin/verify-review-hop`; `BounceLedger`; `bin/review-autopilot` arm, read, head, list | Self-review, a blind pick, merging an unseen head | 2026-08-13 Carl picked for Carl; 2026-09-20 a 301 armed a merge | 30 | KEEP · kept: `guards-review-and-release` |

## 7. Release (102)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| `bin/release.rb#status` `--clean-only`; held-`merged` warning and abort in `prepare` and `merge`; `Release::SweepPlan` blocked half-ship | Board stamps that disagree with git | 2026-08-13 half-ship | 4 | BY CONSTRUCTION: `merged` and `pr_urls` derive from git, so the stamps cannot disagree · kept against the verdict: `guards-review-and-release`. Each is the read before the `accepted` → `release` promote or the `deploy-with-task` expedite, and a task naming a repo with no PR is a real state, not a stamp disagreement |
| Accepted-coverage stop in `bin/release.rb#prepare` | A member repo ahead on `accepted` but not promoted | 2026-08-13 turf +2 · three prepares ran past | 1 | BY CONSTRUCTION: the promote list is git-ahead ∩ member repos · kept against the verdict: `guards-review-and-release`. The construction widens what the promote pushes to `release`; the stop is the read before that push |
| `bin/release.rb#refuse_blind_accepted!` | A suite workflow with no `accepted` trigger | 2026-08-18, 3 of 4 repos | 1 | BY CONSTRUCTION: a CI lint on the workflow files · kept against the verdict: `guards-review-and-release`. The refusal reads other repos' workflows on `origin/accepted` before the promote; a hub CI lint cannot see them, so each repo needs its own lint first |
| `bin/release.rb#dispatch_and_watch` no baseline, no run found | Reading someone else's run | rel-20260922-7210bd and -a299ae · 2 | 2 | BY CONSTRUCTION: dispatch with a correlation id in the run name · kept against the verdict: `guards-review-and-release`. `dispatch_and_watch` also dispatches `prod-deploy.yml`, so the baseline read guards the production deploy's verdict; the correlation id needs the workflows' `run-name` first |
| `bin/release.rb#wait_for_boot` failure in `prepare` | Exits 0 when QA never boots | /up-smoke race | 1 | BY CONSTRUCTION: the prepare exits nonzero · applied: `guards-review-and-release` (exit 3, `Release::Cli::PREPARE_QA_NOT_GREEN_EXIT`) |
| `bin/release.rb#run_post_deploy` unroutable command; `ShipSequence.missing_deploy_commands` | A command or deploy script that names no app | chain-ops 2026-08-22 | 2 | BY CONSTRUCTION: a registry lint at load · kept against the verdict: `guards-review-and-release`. Both guard a `post_deploy` run or a production deploy. The `post_deploy_cmd` comes from task metadata and the deploy script is a file in the sibling checkout, and a load-time registry lint sees neither |
| Dirty gem primary in `bin/release.rb#validate_gems_for_qa` and `bin/release.rb#ship_preflight` | Publishing uncommitted gem code | 2026-07-12 | 2 | BY CONSTRUCTION: build the gem only in the ship workspace · kept against the verdict: `guards-review-and-release`. Both guard the gem publish, which this card keeps |
| CLI (argv, confirm, Ruby, test command, lock dir, conductor); promotion (review gate, slug, expedite, ladder, parked holds, `#refuse_red_accepted!`, `#refuse_misfiled_changelog!`, promote PR, `--match-head-commit`, stale tree, merge-forward and read-back); QA (G3, self-gated gems, run conclusion, QA registry, post-deploy failure, metrics refresh, member evidence, suite bundle, gate workspace and DB, `bin/qa-server` (4), `bin/qa-intake`) | Promoting red, blind or partial work | rel-20260809-3b8f3d; rel-20260812-3f1f9b | 46 | KEEP · kept: `guards-review-and-release` |
| Gems (allocation, changelog, version commit, relock, roll, consumers, refs, CI, stranded work, publish, tag, index wait, lock bump, migrations, schema, consumer and producer locks, `Release::LockDrift`, detached checkout) | An irreversible publish on the wrong version or tree | rel-20260811-573804; 0.48.0 stranded | 20 | KEEP · kept: `guards-review-and-release` |
| Production (state, mode, G4, skip reason, `ShipAuthority.take!`, workspace pin, re-pin, push, advance, deploy, seal, smoke, finalize, live verdict, reseal, restore); claims (`#acquire_conductor_claim!`, `ReleaseClaimCli` (3), presence, flock); merge (`MergeCommand`, `ZapRevalidation`, `MergeRefBase`, `UpstreamMisfile`); `bin/gate`, `bin/conductor`, archive, notes, retro | An unapproved or untested deploy; two conductors | rel-20260720-1fc111; rel-20260921-e59955 | 23 | KEEP. The gate role of the gate workspace has no callers left · kept: `guards-review-and-release` |

## 8. Docs and citation guards (42)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| Citation lanes 1, 4, 5 and the grammar self-tests | Line rot | 2026-09-14, eight rotted `bin/release.rb` citations | 4 | DELETE once lane 3 reaches 0 (decision 3) · applied: `guards-docs-and-citations` |
| Lane 3 `#test_no_citation_names_a_line` | Any `path:line` citation | Ceiling 77 → 55 → 0 | 1 | BY CONSTRUCTION (decision 3) · applied: `guards-docs-and-citations` (every citation a seam, ceiling 0) |
| Lane 2 `#test_every_seam_citation_lands_on_a_definition`; `assert_census_is_real` | A seam naming nothing; a vacuous scan | · | 2 | KEEP · kept: `guards-docs-and-citations` |
| Single-fact prose pins: `token_session_mechanism_claims_test.rb`, `credential_isolation_claims_test.rb`, `token_session_sop_claims_test.rb`, `fast_lane_teaches_agent_test.rb`, `generator_record_tripwire_test.rb` | A sentence that restates code | PR 1691; 2026-08-28 | 5 | DELETE the claims and the pins; cite the seam · applied: `guards-docs-and-citations` |
| Second-copy docs tests under `test/docs/`: portrait extension, approval-drop residuals, archive collision, rotation SOP registration, Cyvasse bounce figure, hub-only scripts, installer prescriptions and scope (2), live-score-watch claims, parse-error redaction, misfile row, reclaim channels, handoff mint, review lane, share-insights precondition, ship docs sync, submit-wait, dependency flags, zap control lane, zap artifacts | A doc that drifts from the code it restates | One fire each, 2026-08 to 2026-09 | 20 | BY CONSTRUCTION: generate the row from its source, cite by seam, or have the command print what the doc restates · applied: `guards-docs-and-citations` (review lane keeps its two entry-doc ordering checks) |
| `test/lib`: app ids, `.env.example` pointers, remedy hints | Same, for config | 2026-08-30; 2026-09-20 | 3 | BY CONSTRUCTION: ids in config; `.env.example` from the inventory; one hint helper · applied: `guards-docs-and-citations` (ids, `.env.example`); remedy hints: `remedy-hints-through-one-helper` (every hub-only remedy prints through `bin/lib/remedy.rb`; the sweep is deleted) |
| Behavioural docs tests: rotation shell, orphan shell variables, fast-lane hub paths, throwaway worktrees, zap freshness; `engine_version_claims_test.rb`, `retired_names_sweep_test.rb` | An SOP whose shell fails, or a ban on restating a generated fact | 2026-09-09, ten Heroku apps and 57 `.env` files | 7 | KEEP · kept: `guards-docs-and-citations` |

## 9. Registry guards and ratchets (34)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| Stale-entry timings guard | See decision 4 | 2026-10-06 | 1 | DELETE · applied: `guards-registries-and-ratchets` |
| `sop_registry_docs_test.rb`, `sop_registry_install_test.rb`, `start_here_label_guard_test.rb` | Index, `claude.md`, Start Here and disk disagreeing | 2026-09-04 | 3 | BY CONSTRUCTION: generate the tables from the SOP files · applied: `guards-registries-and-ratchets` (`bin/sop-registry`; the install test keeps its sandbox proofs) |
| `task_block_kinds_parity_test.rb`; seed ⊆ `Task::SOUL_ROSTER`; open-intents SQL and Ruby parity; devops identifier keys; comma-list flags; `app_registry_test.rb`; QA_ENV declared; Rails lane matrix; `bin_help_flag_class_test.rb` | Two hand copies drifting | 2026-09-15; 2026-10-06 | 9 | BY CONSTRUCTION: one source each (model validates block kinds; roster from the seed; one implementation; one key map; registries from `config/apps.yml`; loader sets QA_ENV; matrix from `config/rails_lane.yml`; a shared argv parser) · applied: `guards-registries-and-ratchets` for seven of nine (block kinds, roster, one implementation, one key map for both list guards, QA_ENV, Rails matrix); kept: `app_registry_test.rb` and `bin_help_flag_class_test.rb`, each its own migration |
| Skip count (exact), frozen hotspot sizes | Any change, up or down; 26 commits of ceiling edits | 2026-08-14 | 2 | BY CONSTRUCTION: compare with the merge base, store nothing · applied: `guards-registries-and-ratchets` |
| e2e contract arithmetic | See decision 7 | · | 1 | BY CONSTRUCTION · applied: `guards-registries-and-ratchets` (`bin/lib/e2e_spec_census.rb`) |
| Release registry answers; shape tiers; web2 boundary; engine pin; image registry; assertion-free ban; ratchet schema; e2e quarantine ceiling; e2e modifiers; Rails skip ceiling; ratchet baseline; job and apt timeouts; fence cap; scan floors (2); payload budget; Puma connection budget | Real preconditions and one-way ratchets | 2026-08-09 H12 outage; 2026-08-18 runner incident | 18 | KEEP · kept: `guards-registries-and-ratchets` |

## 10. App validations and API refusals (49)

| Guard | Refuses → prevents | Trigger · fires | n | Disposition |
|---|---|---|---|---|
| `Task#title_within_word_range`, `Task#acceptance_bullets_within_word_range` | A long title or bullet | v3 section 7 | 2 | DELETE the refusal, keep a warning (v3 decided defaults and warnings) |
| `Task::DEVOPS_COLUMN_KEYS` raise in `normalize_devops_metadata` | A column key written as a devops key → 422 | 156 of 1,586 tasks, 2026-09-02 | 1 | BY CONSTRUCTION: route `dependencies` and `epic_slug` to their columns; refuse only server-owned keys |
| `Task#normalize_devops_map_pair` | A `pr_urls` entry under the wrong repo | · | 1 | BY CONSTRUCTION: key by the URL's repo |
| `Task#guard_approval_request_stage!` | "One sentence on three surfaces" | approval-write-drops-at-submitted | 1 | BY CONSTRUCTION: the CLI and the doc quote the 422 body |
| `Release#at_most_one_active_release` | A second active release | · | 1 | BY CONSTRUCTION: a partial unique index |
| `ReleaseEvent#required_usage_for_agent_completion` and three controllers' `validate_usage!` | Completion without usage, four copies | · | 2 | BY CONSTRUCTION: one concern |
| `GateRunsController` re-implemented grain check; `TaskReviewClaimsController` bodiless 204 | A second copy; a refusal with no reason | · | 2 | BY CONSTRUCTION: let `RecordInvalid` speak; return the reason |
| Task enums, dependencies and epic (normalize, then refuse), approval status, review check-in, intent event, builder stamp, clamps, race-tolerant create, `Ci::ReviewGate`, `ReviewPendingAction` (3), `DeskRecord` (2), `GateRun`, `Devops::Windows`, `Release#add` and states, `Release::Conductor`, `CredentialRecord`, learning and claim integrity, content claims, domain validations (one row for about 300 sites) | Invalid records; history rewrites; an auto-merge on one repo's CI | 2026-08-29 PR 1073; 2026-09-17 int4 clamp | 26 | KEEP. No stage-transition guard exists for tasks |
| API: bearer and rescue folds, unsupported index params, intent, devops 422 fold, pending-action arm, conductor reassign, desk records, contents, music videos, webhook signature, game recaps, sessions, heartbeat grader, admin wall and local-only, web task forms | Bad tokens and inputs | `?status=submitted` returned every task | 13 | KEEP |

## What Alex decides

Accept or overrule the ten decisions, then the group dispositions. An accepted
row becomes a task on this epic; a KEEP needs nothing. Builders' evidence and the
sweep notes live in the epic plan,
`/Users/alex/projects/.agents/epics/platform-audit-refactors.md`.
