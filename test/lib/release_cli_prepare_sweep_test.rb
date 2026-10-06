# frozen_string_literal: true

# `bin/release prepare`'s sweep and promote: detection, multi-repo candidates, the
# stale-tree gate, accepted -> release promotion, --task and --expedite.
#
# Part of the bin/release CLI suite, split by subcommand from the old
# test/lib/release_cli_test.rb (release-cli-tests-by-subcommand, 2026-10-05). The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_prepare_sweep_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliPrepareSweepTest < ReleaseCliHarness
  def test_prepare_is_an_idempotent_noop_when_nothing_is_detected_and_nothing_active
    out = run_cli(["--yes"], call: "prepare; puts('CLEAN-EXIT')", setup: NOOP_PREP_STUB)

    assert_includes out, "Nothing to prepare", "an empty queue reports, never fabricates work"
    assert_includes out, "idempotent no-op"
    assert_includes out, "CLEAN-EXIT", "the no-op exits zero (schedule-ready)"
    refute_includes out, "bin/qa-server deploy", "nothing deploys on a no-op"
  end

  def test_prepare_refuses_a_multi_repo_candidate_whose_pr_record_is_incomplete
    out = run_cli(["--dry-run"], setup: multi_repo_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836" }),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a multi-repo task with one PR must not sweep"
    assert_includes out, "turf-monster", "the refusal names the repo with no PR url"
    assert_includes out, "NOTHING was promoted", "fail-closed BEFORE the promote"
    refute_includes out, "NO-ABORT"
    refute_includes out, "promote accepted → release", "nothing may be promoted"
    refute_includes out, "SWEEP-CALL", "nothing may be recorded"
  end

  # THE GEM RELEASE MUST NOT BE REFUSED. A `library` candidate names its gem plus
  # the consumers that adopt it and carries ONE PR — the gem's — because a
  # consumer's change in a gem release is committed by the pipeline itself
  # (bump_consumer_locks_for_qa), not by a person opening a PR. Live shape:
  # guard-engine-migration-rollback, four repos behind one studio-engine PR.
  # Without the `kind: "gem"` exemption this abort would fire on every engine
  # release, demanding a URL that does not exist.
  def test_prepare_does_not_refuse_a_GEM_candidate_carrying_only_the_gem_pr
    out = run_cli(["--dry-run"],
                  setup: multi_repo_stub(
                    tasks: [ { "slug" => "guard-engine-migration-rollback", "stage" => "reviewed",
                               "merged" => "accepted", "kind" => "gem",
                               "pr_url" => "https://gh/pr/124", "repo" => "studio-engine",
                               "repos" => [ "studio-engine", "mcritchie-studio", "turf-monster" ],
                               "pr_urls" => { "studio-engine" => "https://gh/pr/124" } } ]
                  ),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "NO-ABORT", "a gem release with one gem PR must sweep"
    refute_includes out, "incomplete PR record"
    assert_includes out, "promote accepted → release in studio-engine"
    assert_includes out, "promote accepted → release in mcritchie-studio",
                     "the consumers still ride the promote — only the PR demand is exempt"
  end

  # The CONTROL: the identical candidate as an APP is the 2026-08-13 incident, and
  # is still refused. Only the gem kind earns the pass.
  def test_prepare_refuses_the_same_candidate_when_it_is_an_APP
    out = run_cli(["--dry-run"],
                  setup: multi_repo_stub(
                    tasks: [ { "slug" => "guard-engine-migration-rollback", "stage" => "reviewed",
                               "merged" => "accepted", "kind" => "app",
                               "pr_url" => "https://gh/pr/124", "repo" => "studio-engine",
                               "repos" => [ "studio-engine", "mcritchie-studio", "turf-monster" ],
                               "pr_urls" => { "studio-engine" => "https://gh/pr/124" } } ]
                  ),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED"
    assert_includes out, "incomplete PR record"
    refute_includes out, "NO-ABORT"
  end

  def test_prepare_promotes_EVERY_repo_a_multi_repo_candidate_names
    out = run_cli(["--dry-run"], call: "prepare",
                  setup: multi_repo_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                    "turf-monster" => "https://gh/pr/305" }))

    assert_includes out, "promote accepted → release in mcritchie-studio"
    assert_includes out, "promote accepted → release in turf-monster",
                     "THE fix: the promote list is every repo the task NAMES, not the one its pr_url parses to"
  end

  # The check `bin/release status` already printed and no gate consulted: git says a
  # repo's `accepted` carries commits, and this sweep would not carry it.
  #
  # SCOPED TO MEMBER-NAMED REPOS. The candidate here is the shape a PARTIAL earlier
  # promote leaves behind: `half-promoted-patch` names [hub, turf] and is stamped
  # merged:"release", so it is RECORDED as a member but contributes nothing to the
  # promote list — while turf's `accepted` is still ahead. That is exactly the
  # 2026-08-13 half-ship arriving one sweep later, and the guard must still bite.
  def test_prepare_refuses_when_a_MEMBER_NAMED_repo_ahead_on_accepted_is_not_promoted
    out = run_cli(["--yes"],
                  setup: multi_repo_stub(
                    tasks: [ HUB_ONLY_CANDIDATE,
                             { "slug" => "half-promoted-patch", "stage" => "reviewed", "merged" => "release",
                               "pr_url" => "https://gh/pr/836", "repo" => "mcritchie-studio",
                               "repos" => [ "mcritchie-studio", "turf-monster" ],
                               "pr_urls" => { "mcritchie-studio" => "https://gh/pr/836",
                                              "turf-monster" => "https://gh/pr/305" } } ],
                    ahead: [ { "repo" => "mcritchie-studio", "ahead" => 2 },
                             { "repo" => "turf-monster", "ahead" => 2 } ]
                  ),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED"
    assert_includes out, "turf-monster", "the refusal names the repo that would be left behind"
    assert_includes out, "NOTHING was promoted, recorded or deployed"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GH-MERGE", "fail-closed BEFORE the irreversible promote"
    refute_includes out, "SWEEP-CALL"
  end

  # THE FALSE ABORT this guard shipped with, and the reason it is scoped: the git
  # read spans EVERY registered repo, but `--task` deliberately narrows the sweep.
  # Avi's documented per-app hold-back (qa-release.md, "sweep only the included
  # apps") IS a --task run, and a held-back app's reviewed work sits on `accepted`
  # BY CONSTRUCTION — so the unscoped comparison refused the hold-back every time,
  # with no --override and a message whose prescribed fixes would have undone it.
  # Here turf and industries are ahead and no member names either: prepare must
  # promote the hub and carry on.
  def test_prepare_allows_a_task_narrowed_holdback_over_repos_no_member_names
    out = run_cli(["--yes"],
                  setup: multi_repo_stub(
                    tasks: [ HUB_ONLY_CANDIDATE ],
                    ahead: [ { "repo" => "mcritchie-studio", "ahead" => 2 },
                             { "repo" => "turf-monster", "ahead" => 7 },
                             { "repo" => "mcritchie-industries", "ahead" => 3 } ]
                  ),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "NO-ABORT", "a hold-back sweep must not be refused for the repo it is holding back"
    refute_includes out, "prepare refused"
    refute_includes out, "turf-monster", "a repo no member names is out of this guard's scope"
    assert_includes out, "GH-MERGE", "the included app still promotes"
    assert_includes out, "SWEEP-CALL", "…and still records"
  end

  def test_prepare_proceeds_when_every_accepted_ahead_repo_rides_the_promote
    out = run_cli(["--yes"], call: "prepare",
                  setup: multi_repo_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                    "turf-monster" => "https://gh/pr/305" }))

    assert_includes out, "GH-MERGE", "a fully-covered promote is not refused"
    assert_includes out, "SWEEP-CALL", "…and still records"
  end

  # The transcript line is the last place a human can catch a half-ship before it is
  # recorded, and printing only the primary repo is what made 2026-08-13 look
  # complete. A multi-repo candidate names every repo it carries; a single-repo one
  # renders exactly as it always did.
  def test_prepare_sweep_line_names_every_repo_a_multi_repo_candidate_carries
    out = run_cli(["--dry-run"], call: "prepare",
                  setup: multi_repo_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                    "turf-monster" => "https://gh/pr/305" }))

    assert_includes out, "sweep land-rails-security-patch (reviewed · merged: accepted) · " \
                         "mcritchie-studio, turf-monster · https://gh/pr/836"
  end

  # [integration] MUTATION DIRECTION 1 — the stranded commit is CAUGHT, and the
  # run does not reach the deploy at all.
  def test_prepare_refuses_when_a_commit_is_stranded_on_accepted
    out = run_cli(["--yes"], call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end},
                  setup: stale_tree_stub)

    assert_includes out, "ABORTED", "a stale tree must abort, never fall through"
    refute_includes out, "NO-ABORT"
    # THE WHOLE DEFECT: the sweep must never print success over a stale tree.
    refute_includes out, "✓ Assembled rel-strand", "prepare must NOT report the candidate assembled"
    refute_includes out, "QA-DEPLOY", "…and must not deploy the old tree to QA first"
  end

  # [integration] The refusal has to be ACTIONABLE: the repo, the stranded SHA,
  # and the recovery with both filled in. A refusal that does not name its remedy
  # just moves the confusion.
  def test_prepare_stale_tree_refusal_names_the_commits_and_the_recovery
    out = run_cli(["--yes"], call: %{begin; prepare; rescue SystemExit => e; puts("ABORTED: " + e.message); end},
                  setup: stale_tree_stub)

    assert_includes out, "1 commit stranded on `accepted`"
    assert_includes out, "ed4d16a Correct the public price claim", "the SHA and subject, read from git log"
    assert_includes out, "gh pr create --repo McRitchie-Studio/mcritchie-studio --base release --head accepted",
                     "the recovery names the repo it resolved from the remote"
    assert_includes out, "--match-head-commit ed4d16a", "the recovery merge is pinned at the accepted head"
    assert_includes out, "bin/release prepare", "…and the re-run that finishes it"
    assert_includes out, "NOTHING was published, gated, or deployed"
  end

  # [integration] WHY it refuses rather than quietly promoting onto a QA-green
  # candidate — the judgment call, printed where the operator will read it.
  def test_prepare_stale_tree_refusal_explains_why_it_will_not_re_promote
    out = run_cli(["--yes"], call: %{begin; prepare; rescue SystemExit; end}, setup: stale_tree_stub)

    assert_includes out, "already `assembled` (QA-green)"
    assert_includes out, "will NOT silently promote onto it"
    assert_includes out, "BOARD STAMPS", "and why the promote missed it in the first place"
  end

  # [integration] MUTATION DIRECTION 2 — the one people skip. A genuinely
  # up-to-date assembled candidate must still PASS. Interrupted sweeps are common
  # (a foreground shell timeout kills one mid-run); if re-runs started refusing,
  # every one of them would become a manual repair and the lane would be unusable.
  def test_prepare_still_re_runs_a_genuinely_current_assembled_candidate
    out = run_cli(["--yes"], call: "prepare", setup: stale_tree_stub(ahead: 0))

    refute_includes out, "prepare refused", "a level ladder must not refuse — resumability depends on it"
    assert_includes out, "carries every `accepted` commit (mcritchie-studio)", "the gate says what it verified"
    assert_includes out, "QA-DEPLOY", "the re-run still deploys QA"
    assert_includes out, "Assembled rel-strand", "…and still reports the candidate assembled"
  end

  # [integration] A failed read is not a clean read. An unreadable rung on a repo
  # the candidate is about to DEPLOY is unverified, and unverified is stale.
  def test_prepare_refuses_when_the_accepted_rung_cannot_be_read
    out = run_cli(["--yes"], call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end},
                  setup: stale_tree_stub(rev_list_ok: false))

    assert_includes out, "ABORTED"
    assert_includes out, "could NOT be read"
    assert_includes out, "a failed read is not a clean read"
    refute_includes out, "QA-DEPLOY", "an unmeasurable rung must not be deployed over"
    refute_includes out, "NO-ABORT"
  end

  # [integration] The gate is a LIVE-run gate: a dry run takes no fetch, so it
  # says so rather than passing on an unmeasured signal it never took.
  def test_prepare_dry_run_says_the_stale_tree_gate_runs_live_only
    out = run_cli(["--dry-run"], call: "prepare", setup: stale_tree_stub)

    assert_includes out, "a dry run takes no fetch"
    refute_includes out, "prepare refused", "a preview must not manufacture a refusal from an unmeasured rung"
  end

  # [integration] The gate runs BEFORE the deploy half's irreversible work. This
  # is what makes a refusal free: no gem is on RubyGems, no QA app has moved, and
  # member stages are untouched, so the re-run after the hand-landed batch PR is
  # a clean resume rather than a repair.
  def test_prepare_stale_tree_gate_precedes_the_merge_forward_gate_and_deploy
    out = run_cli(["--yes"], call: %{begin; prepare; rescue SystemExit; end}, setup: stale_tree_stub)

    verify = out.index("verify: `release` carries `accepted`")
    refute_nil verify, "the gate must announce itself: #{out}"
    ["merge-forward", "pre-QA gate", "QA-DEPLOY"].each do |later|
      idx = out.index(later)
      assert(idx.nil? || idx > verify, "#{later} must not run before the stale-tree gate")
    end
  end

  def test_prepare_promotes_accepted_to_release_and_records_the_members
    out = run_cli(["--yes"], call: "prepare", setup: SWEEP_FLOW_STUB)

    # ONE accepted→release batch PR promotes the whole repo — NOT one merge per task.
    assert_equal 1, out.scan("GH-MERGE").size, "one accepted→release batch PR per repo, not one per task"
    assert_includes out, "GH-MERGE https://gh/pr/accepted-release"
    assert_includes out, "promote accepted → release in mcritchie-studio"
    refute_includes out, "GH-MERGE https://gh/pr/9", "no per-feat-PR merge — review already landed it on accepted"

    # The crash-recovery straggler (merged:release) records but is not re-promoted.
    assert_includes out, "skip promote for task-swept — already merged: release"

    # The anomaly (merged:"") is warned + left reviewed — never an abort in prepare.
    assert_includes out, "task-held"
    assert_includes out, "left `reviewed` (re-review to heal)"

    # ONE batched record write sweeps the two members with code (not the held one).
    assert_equal 1, out.scan("SWEEP-CALL").size, "the sweep records in ONE heroku run"
    sweep = out.lines.find { |l| l.start_with?("SWEEP-CALL") }
    assert_includes sweep, "task-accepted"
    assert_includes sweep, "task-swept"
    refute_includes sweep, "task-held", "an unstamped reviewed member is never swept onto the RC"

    # QA booted green → the QA-green flip fires and the RC assembles.
    assert_equal 1, out.scan("QA-GREEN-CALL").size, "QA-green flips the swept members via qa_green!"
    assert_includes out, "Assembled rel-sweep"
  end

  def test_prepare_dry_run_previews_the_promote_without_recording
    out = run_cli(["--dry-run"], call: "prepare", setup: SWEEP_FLOW_STUB)

    assert_includes out, "sweep task-accepted (reviewed", "the dry run previews the detected sweep"
    assert_includes out, "promote accepted → release in mcritchie-studio", "the dry run previews the ONE batch PR"
    assert_includes out, "skip promote for task-swept — already merged: release"
    refute_includes out, "GH-MERGE", "a dry run merges nothing"
    refute_includes out, "GH-CREATE", "a dry run opens no PR"
    refute_includes out, "SWEEP-CALL", "a dry run records nothing"
    refute_includes out, "QA-GREEN-CALL", "a dry run flips nothing"
  end
  def test_prepare_dry_run_promotes_one_accepted_to_release_batch_pr_not_one_per_task
    out = run_cli(["--dry-run"], call: "prepare", setup: ONE_BATCH_STUB)

    promote_lines = out.lines.select { |l| l.include?("promote accepted → release in mcritchie-studio") }
    assert_equal 1, promote_lines.size,
                 "3 reviewed tasks in one repo → ONE accepted→release batch PR, not 3 per-task merges"
    %w[1 2 3].each do |n|
      refute_match(%r{gh pr merge https://gh/pr/#{n}}, out, "no per-feat-PR merge in the accepted-ladder sweep")
    end
  end

  # ahead == 0: accepted is level with release (a prior run promoted it, or nothing
  # new). promote SKIPS the batch PR — the caller still records + deploys.
  def test_promote_skips_the_batch_pr_when_accepted_is_level_with_release
    setup = %(def repo_path(_r) = #{self.class.stub_repo.inspect}\n) + <<~'RUBY'
      def sh(*a, **k)
        return ["", true] if a[0] == "git" && a.include?("fetch")
        return ["0", true] if a[0] == "git" && a.include?("rev-list")   # ahead == 0
        $stdout.puts("GH " + a.join(" ")) if a[0] == "gh"
        ["", true]
      end
    RUBY
    out = run_cli([], call: %(promote_accepted_to_release!(["mcritchie-studio"])), setup: setup)

    assert_includes out, "level with `release` — nothing to promote"
    refute_includes out, "GH ", "no gh PR is opened or merged when accepted is level with release"
  end

  # ahead > 0: promote opens/reuses ONE `--base release --head accepted` batch PR
  # and merges it.
  def test_promote_opens_and_merges_one_batch_pr_when_accepted_is_ahead
    setup = %(def repo_path(_r) = #{self.class.stub_repo.inspect}\n) + <<~'RUBY'
      def sh(*a, **k)
        return ["", true] if a[0] == "git" && a.include?("fetch")
        return ["3", true] if a[0] == "git" && a.include?("rev-list")   # accepted 3 ahead
        return ["git@github.com:McRitchie-Studio/mcritchie-studio.git", true] if a[0] == "git" && a.include?("remote")
        return ["", true] if a[0] == "gh" && a[2] == "list"             # no existing batch PR
        if a[0] == "gh" && a[2] == "create"
          $stdout.puts("CREATE " + a.join(" "))
          return ["https://gh/pr/batch", true]
        end
        if a[0] == "gh" && a.include?("merge")
          $stdout.puts("MERGE " + a.find { |x| x.to_s.start_with?("https") }.to_s)
          return ["", true]
        end
        ["", true]
      end
    RUBY
    out = run_cli([], call: %(promote_accepted_to_release!(["mcritchie-studio"], label: "rel-x")), setup: setup)

    assert_includes out, "promote accepted → release in mcritchie-studio (3 commits)"
    assert_equal 1, out.scan("CREATE").size, "opens exactly ONE batch PR"
    assert_includes out, "--base release"
    assert_includes out, "--head accepted"
    assert_equal 1, out.scan("MERGE").size, "merges the batch PR once"
    assert_includes out, "MERGE https://gh/pr/batch"
  end

  # --task names a slug detection DROPPED (typo, or neither `reviewed` nor an
  # assembled straggler): the filter runs BEFORE the review-gate screen, so
  # without the loud fail the slug vanished silently and the run could still end
  # "✓". prepare must abort BEFORE any merge or deploy.
  def test_prepare_task_flag_fails_loudly_when_a_named_slug_is_not_sweepable
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        { "tasks" => [
            { "slug" => "task-real", "stage" => "reviewed", "merged" => "", "pr_url" => "https://gh/pr/9", "repo" => "mcritchie-studio" }
          ],
          "release" => nil,
          "screen" => { "rows" => [], "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
      end
    RUBY
    out = run_cli(["--yes", "--task", "task-real", "--task", "task-typo"], setup: setup,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a dropped --task slug must abort — never a silent drop / false success"
    assert_includes out, "task-typo", "the abort names the missing slug"
    assert_includes out, "not sweepable", "the abort names the eligibility rule"
    assert_includes out, "Nothing was merged or deployed", "the loud fail lands before any side effect"
    refute_includes out, "NO-ABORT"
    refute_includes out, "gh pr merge", "no PR merges after the loud fail"
    refute_includes out, "bin/qa-server deploy", "no QA deploy after the loud fail"
  end

  # The surviving --task list still previews/sweeps normally (the loud fail only
  # fires on a MISSING slug, not on curation itself).
  def test_prepare_task_flag_sweeps_a_named_slug_that_survives_detection
    out = run_cli(["--dry-run", "--task", "task-accepted"], call: "prepare", setup: SWEEP_FLOW_STUB)

    assert_includes out, "sweep task-accepted (reviewed", "the named survivor previews"
    refute_includes out, "not sweepable", "no loud fail when every named slug survived"
  end

  def test_prepare_expedite_promotes_when_accepted_still_carries_only_that_task
    out = run_cli(["--yes", "--task", "task-accepted", "--expedite"], call: "prepare",
                  setup: expedite_stub(accepted: [{ "slug" => "task-accepted", "title" => "The one task" }]))

    assert_includes out, "re-prove the `accepted → release → main` ladder", "the guard runs at the promote"
    assert_includes out, "attributed to the expedited task `task-accepted`"
    assert_includes out, "GH-MERGE https://gh/pr/accepted-release", "a clean ladder still PROMOTES — the lane stays usable"
    assert_includes out, "SWEEP-CALL", "…and still records"
  end

  def test_prepare_expedite_refuses_a_task_the_autopilot_landed_mid_review
    out = run_cli(["--yes", "--task", "task-accepted", "--expedite"],
                  setup: expedite_stub(accepted: [{ "slug" => "task-accepted", "title" => "" },
                                                  { "slug" => "autopilot-landed", "title" => "Merged mid-review" }]),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "the promote-time guard is what actually protects production"
    assert_includes out, "autopilot-landed", "the refusal names the work that would have ridden along"
    assert_includes out, "full-cycle", "it offers shipping the whole release instead"
    assert_includes out, "NOTHING was promoted, recorded, or deployed"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GH-MERGE", "fail-closed BEFORE the irreversible promote"
    refute_includes out, "SWEEP-CALL", "nothing recorded"
    refute_includes out, "QA-GREEN-CALL", "nothing flipped"
  end

  def test_prepare_expedite_refuses_unstamped_commits_on_accepted
    out = run_cli(["--yes", "--task", "task-accepted", "--expedite"],
                  setup: expedite_stub(accepted: []),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit; puts("ABORTED"); end})

    assert_includes out, "ABORTED", "commits on `accepted` with no stamped owner are never attributed away"
    assert_includes out, "DISAGREE", "the board/git disagreement is named, not swallowed"
    refute_includes out, "GH-MERGE"
    refute_includes out, "NO-ABORT"
  end

  def test_prepare_expedite_requires_exactly_one_named_task
    out = run_cli(["--yes", "--expedite"], setup: SWEEP_FLOW_STUB,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "an expedite with no named task has nothing to attribute to"
    assert_includes out, "exactly one `--task <slug>`"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GH-MERGE"
  end

  # A bare `prepare` — the normal full-queue sweep, where promoting ALL of
  # `accepted` is exactly the intent — must be completely unaffected by the
  # opt-in guard. Otherwise the fix breaks the pipeline it was meant to protect.
  def test_prepare_without_expedite_never_runs_the_ladder_guard
    out = run_cli(["--yes"], call: "prepare",
                  setup: expedite_stub(accepted: [{ "slug" => "someone-else", "title" => "Parked" }]))

    refute_includes out, "re-prove the `accepted → release → main` ladder", "the guard is opt-in"
    assert_includes out, "GH-MERGE https://gh/pr/accepted-release", "the normal sweep promotes as before"
    assert_includes out, "SWEEP-CALL"
  end
end
