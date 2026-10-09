# frozen_string_literal: true

# `bin/release merge` and `eject`: membership, promote, the review gate, the assembler
# claim, record_merged_main and the batch runner snippets.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_merge_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliMergeTest < ReleaseCliHarness
  # --- eject: block-on-regression (detach + block ONE offender, keep the rest) ---

  def test_eject_records_the_conductor_eject_and_prints_the_revert_guidance
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "slug" => "rel-active", "state" => "assembling" }   # the active RC to claim
        else
          $stdout.puts("EJECT-CALL " + ruby.gsub("\n", " "))
          { "slug" => "task-bad", "stage" => "blocked", "merged" => nil }
        end
      end
      def conductor_claim(*a) = ReleaseClaimCli::OK
    RUBY
    out = run_cli(["task-bad", "--feedback", "integration regression on release"], call: "eject", setup: setup)

    eject = out.lines.find { |l| l.start_with?("EJECT-CALL") }
    assert_includes eject, "Release::Conductor.eject!", "the record side detaches + blocks via eject!"
    assert_includes eject, "integration regression on release", "the feedback threads into the qa_feedback note"
    assert_includes out, "task-bad → blocked (rework)"
    assert_includes out, "git revert -m 1", "the git unwind guidance is printed"
    assert_includes out, "bin/release prepare", "…ending at the self-healing re-run"
  end

  # --- eject (FIX b): the assembler claim SERIALIZES the membership detach ------
  # eject! MUTATES release-candidate membership (release_slug + `merged` cleared) — the
  # SAME assembler-lane write prepare/merge guard. A concurrent eject during a prepare
  # sweep would race that write, so eject takes the per-release `assembler` claim first.
  # These drive bin/release IN A SUBPROCESS with conductor_claim STUBBED, proving the
  # runtime effect the source-ordering wiring test can only assert structurally.

  # HELD claim → eject stands DOWN before the detach: the observable effect is that the
  # membership mutation (EJECT-CALL) NEVER runs — eject refuses rather than racing.
  def test_eject_stands_down_before_the_membership_detach_when_the_assembler_claim_is_held
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "slug" => "rel-active", "state" => "assembling" }    # the active RC the claim keys on
        else
          $stdout.puts("EJECT-CALL " + ruby.gsub("\n", " "))     # the membership mutation — must NOT run
          { "slug" => "task-bad", "stage" => "blocked", "merged" => nil }
        end
      end
      def conductor_claim(*a); $stdout.puts("CLAIM-CHECK " + a.join(" ")); ReleaseClaimCli::STOOD_DOWN; end
    RUBY
    out = run_cli(["task-bad"], setup: setup,
                  call: "begin; eject; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "CLAIM-CHECK acquire rel-active --role assembler",
                     "eject resolves the active release, then CONSULTS the per-release assembler claim BEFORE mutating membership"
    assert_includes out, "ABORTED", "a held assembler claim (STOOD_DOWN) stands eject down"
    assert_includes out, "held by another live release conductor", "and names the stand-down cause"
    refute_includes out, "NO-ABORT", "eject must not fall through past the claim gate"
    refute_includes out, "EJECT-CALL",
                     "the membership detach (Release::Conductor.eject!) must NOT run — eject serializes BEFORE the write, never racing a concurrent sweep"
  end

  # OK claim → eject holds the claim ACROSS the detach and releases it AFTER: the
  # observable effect is the write-ordering acquire(assembler) → detach → release.
  def test_eject_holds_the_assembler_claim_across_the_detach_then_releases_it
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "slug" => "rel-active", "state" => "assembling" }
        else
          $stdout.puts("DETACH")                                  # the membership mutation
          { "slug" => "task-bad", "stage" => "blocked", "merged" => nil }
        end
      end
      def conductor_claim(op, *a); $stdout.puts("CLAIM-#{op.upcase} " + a.join(" ")); ReleaseClaimCli::OK; end
    RUBY
    out = run_cli(["task-bad"], call: "eject", setup: setup)

    seq     = out.lines.map(&:strip).select { |l| l.start_with?("CLAIM-", "DETACH") }
    acquire = seq.index { |l| l.start_with?("CLAIM-ACQUIRE") }
    detach  = seq.index("DETACH")
    release = seq.index { |l| l.start_with?("CLAIM-RELEASE") }

    assert [acquire, detach, release].all?, "acquire, detach, and release must all occur: got #{seq.inspect}"
    assert_includes seq[acquire], "--role assembler", "the claim taken is the per-release ASSEMBLER lane"
    assert acquire < detach, "the assembler claim is ACQUIRED before the membership detach"
    assert detach < release, "and RELEASED only AFTER the detach — the claim is held ACROSS the whole membership write"
  end

  def test_eject_without_a_slug_aborts_with_usage
    out = run_cli([], call: "begin; eject; rescue SystemExit => e; puts('ABORTED: ' + e.message); end", setup: "")
    assert_includes out, "ABORTED"
    assert_includes out, "usage: bin/release eject"
  end

  # --- record_merged_main: the ship-side merged:"main" stamp -------------------

  def test_record_merged_main_records_the_ff_stamp_through_the_conductor
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        $stdout.puts("MERGED-CALL " + ruby.gsub("\n", " "))
        {}
      end
    RUBY
    out = run_cli(["--yes"], call: %(record_merged_main(["t-a", "t-b"])), setup: setup)

    merged = out.lines.find { |l| l.start_with?("MERGED-CALL") }
    assert_includes merged, "Release::Conductor.record_merged!", "the stamp rides the tested conductor primitive"
    assert_includes merged, "'main'"
    assert_includes merged, "t-a"
    assert_includes merged, "t-b"
  end

  def test_record_merged_main_is_best_effort_and_never_aborts_the_ship
    setup = %(def conductor(ruby, read_only: false) = abort!("record op failed: board blip"))
    out = run_cli(["--yes"], call: %(record_merged_main(["t-a"]); puts("CONTINUED")), setup: setup)

    assert_includes out, "merged:main not recorded", "a board blip WARNS"
    assert_includes out, "CONTINUED", "…and the ship continues (git ffs no-op; ship! re-stamps)"
  end

  def test_record_merged_main_skips_empty_slugs_and_dry_run
    setup = %(def conductor(ruby, read_only: false); $stdout.puts("MERGED-CALL"); {}; end)
    out = run_cli(["--yes"], call: %(record_merged_main([])), setup: setup)
    refute_includes out, "MERGED-CALL", "no members → no write"

    out = run_cli(["--dry-run"], call: %(record_merged_main(["t-a"])), setup: setup)
    refute_includes out, "MERGED-CALL", "a dry run stamps nothing"
  end
  def test_merge_promotes_accepted_and_records_all_named_slugs_in_one_run
    out = run_cli(%w[task-a task-b], call: "merge", setup: MERGE_STUB)

    assert_equal 1, out.scan("RESOLVE-CALL").size, "all slugs resolve in ONE read conductor call"
    # ONE accepted→release batch PR promotes the repo — NOT one merge per feat PR.
    assert_equal 1, out.scan("PROMOTE-MERGE").size, "one accepted→release batch PR per repo"
    assert_includes out, "PROMOTE-MERGE https://gh/pr/batch"
    refute_includes out, "PROMOTE-MERGE https://gh/pr/1", "no per-feat-PR merge — review already landed it on accepted"
    # ONE record write covers both named slugs (single dyno spin-up).
    assert_equal 1, out.scan("ADOPT-CALL").size, "all records run in ONE write conductor call"
    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "task-a"
    assert_includes adopt, "task-b"
    assert_includes adopt, "sweep!", "the batched call drives Release::Conductor.sweep!"
    assert_includes out, "Swept task-a"
  end

  def test_merge_promotes_once_per_distinct_repo_across_a_multi_repo_batch
    setup = PROMOTE_SH + <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "tasks" => [
            { "slug" => "task-a", "merged" => "accepted", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" },
            { "slug" => "task-b", "merged" => "accepted", "pr_url" => "https://gh/pr/2", "repo" => "turf-monster", "stage" => "reviewed" }
          ] }
        else
          $stdout.puts("ADOPT-CALL " + ruby.gsub("\n", " "))
          { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
        end
      end
    RUBY
    out = run_cli(%w[task-a task-b], call: "merge", setup: setup)

    assert_equal 2, out.scan("PROMOTE-MERGE").size, "one accepted→release batch PR per DISTINCT repo, not per task"
    assert_includes out, "promote accepted → release in mcritchie-studio"
    assert_includes out, "promote accepted → release in turf-monster"
  end

  def test_merge_promotes_EVERY_repo_a_multi_repo_task_names
    out = run_cli(%w[land-rails-security-patch], call: "merge",
                  setup: multi_repo_merge_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                          "turf-monster" => "https://gh/pr/305" }))

    assert_equal 2, out.scan("PROMOTE-MERGE").size,
                 "THE fix: one accepted→release batch PR per repo the TASK NAMES, not per pr_url"
    assert_includes out, "promote accepted → release in mcritchie-studio"
    assert_includes out, "promote accepted → release in turf-monster"
    assert_includes out, "ADOPT-CALL", "…and the membership still records"
  end

  def test_merge_refuses_a_multi_repo_task_whose_pr_record_is_incomplete
    out = run_cli(%w[land-rails-security-patch],
                  call: "begin; merge; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end",
                  setup: multi_repo_merge_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836" }))

    assert_includes out, "ABORTED", "a multi-repo task with one PR must not sweep through merge either"
    assert_includes out, "land-rails-security-patch", "the refusal names the task it refused…"
    assert_includes out, "turf-monster", "…and the repo with no PR url"
    assert_includes out, "NOTHING was promoted or recorded"
    refute_includes out, "NO-ABORT"
    refute_includes out, "PROMOTE-MERGE", "fail-closed BEFORE the irreversible promote"
    refute_includes out, "ADOPT-CALL", "and nothing may be recorded"
  end

  # The abort above must be an ABORT, never a silent drop: SweepPlan.compute removes
  # blocked rows before it splits record/held, so without the refusal the named task
  # would vanish from BOTH lists and merge would print a tick over a task it dropped.
  def test_merge_never_silently_drops_the_task_it_refuses
    out = run_cli(%w[land-rails-security-patch],
                  call: "begin; merge; rescue SystemExit => e; puts('ABORTED'); end",
                  setup: multi_repo_merge_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836" }))

    refute_includes out, "✓ Swept", "a dropped task must never read as swept"
  end

  # The record write is the LAST line of defense, and merge's had none: it swept
  # straight into the release with no validate_members! behind it. Now it runs the
  # same validated, transactional write prepare's does.
  def test_merge_record_write_validates_members_inside_a_transaction
    out = run_cli(%w[task-a], call: "merge", setup: SINGLE_MERGE_STUB)

    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "Release.transaction", "a validate_members! raise must roll the sweep back"
    assert_includes adopt, "Release::Conductor.validate_members!",
                    "merge's record write runs the member backstop"
  end

  def test_merge_task_line_names_every_repo_a_multi_repo_task_carries
    out = run_cli(%w[land-rails-security-patch], call: "merge",
                  setup: multi_repo_merge_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                          "turf-monster" => "https://gh/pr/305" }))

    assert_includes out, "task land-rails-security-patch (reviewed · merged: accepted) · " \
                         "mcritchie-studio, turf-monster · https://gh/pr/836"
  end
  def test_merge_single_slug_promotes_and_records
    out = run_cli(%w[task-a], call: "merge", setup: SINGLE_MERGE_STUB)
    assert_equal 1, out.scan("ADOPT-CALL").size
    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "task-a"
    assert_includes out, "Swept task-a"
  end

  def test_merge_with_no_slug_aborts_with_usage
    out = run_cli([], call: "begin; merge; rescue SystemExit => e; puts('ABORTED: ' + e.message); end",
                  setup: MERGE_STUB)
    assert_includes out, "ABORTED"
    assert_includes out, "usage: bin/release merge", "no slug → usage abort"
  end

  # --- accepted-ladder: held abort + straggler skip ----------------------------
  # The retarget/base-guard/overlap machinery retired with the per-feat-PR sweep
  # (review merges feat→accepted; the sweep promotes ONE accepted→release batch PR).
  # What remains for the EXPLICIT `merge` command: a named task must have code on
  # `accepted`, and a straggler already on release is recorded without a re-promote.

  # A named task with NO code on accepted (merged:"") — review never landed its feat
  # PR — is a HARD abort: the operator named it and there is nothing to promote.
  def test_merge_aborts_on_a_named_task_with_no_code_on_accepted
    setup = PROMOTE_SH + <<~'RUBY'
      def conductor(ruby, read_only: false)
        read_only ? { "tasks" => [
          { "slug" => "task-a", "merged" => "", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" }
        ] } : { "slug" => "rel-batch", "state" => "assembling" }
      end
    RUBY
    out = run_cli(%w[task-a], call: "begin; merge; rescue SystemExit => e; puts('ABORTED: ' + e.message); end", setup: setup)

    assert_includes out, "ABORTED", "a named task with no code on accepted aborts the merge"
    assert_includes out, "no code on `accepted`"
    assert_includes out, "task-a"
    refute_includes out, "PROMOTE-MERGE", "nothing promotes when a named task is not on accepted"
  end

  # A straggler already on release (merged:release) records membership but is NOT
  # re-promoted — the crash-recovery skip.
  def test_merge_skips_promote_for_a_straggler_already_on_release
    setup = PROMOTE_SH + <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "tasks" => [
            { "slug" => "task-a", "merged" => "release", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" }
          ] }
        else
          $stdout.puts("ADOPT-CALL " + ruby.gsub("\n", " "))
          { "slug" => "rel-batch", "state" => "assembling" }
        end
      end
    RUBY
    out = run_cli(%w[task-a], call: "merge", setup: setup)

    assert_includes out, "skip promote for task-a — already merged: release"
    refute_includes out, "PROMOTE-MERGE", "a straggler already on release is not re-promoted"
    assert_equal 1, out.scan("ADOPT-CALL").size, "…but it still records membership"
  end
  def test_merge_refuses_an_unreviewed_task_without_override
    # abort writes the message to STDERR (discarded by run_cli) AND raises
    # SystemExit carrying it — capture e.message, mirroring the usage-abort test.
    out = run_cli(%w[task-a], setup: BLOCKED_MERGE_STUB,
                  call: "begin; merge; rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "an unreviewed task aborts the merge"
    assert_includes out, "review gate", "the abort names the review gate"
    assert_includes out, "task-a (submitted)", "it prints exactly which task is in which stage"
    assert_includes out, "--override", "the abort points to the override escape hatch"
    assert_equal 0, out.scan("ADOPT-CALL").size, "nothing is merged or adopted — the guard runs BEFORE gh pr merge"
  end
  def test_merge_override_merges_an_unreviewed_task_and_threads_the_bypass_to_adopt
    out = run_cli(%w[task-a --override], call: "merge", setup: OVERRIDE_MERGE_STUB)

    assert_includes out, "OVERRIDE", "the override banner is printed"
    assert_includes out, "review_bypassed", "the banner names the audit event it records"
    assert_equal 1, out.scan("ADOPT-CALL").size, "the override proceeds to merge + adopt"
    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "override: true", "the adopt snippet threads the audited bypass"
  end

  def test_merge_default_threads_no_override_into_adopt
    # MERGE_STUB returns reviewed tasks + NO screen → the guard is a no-op and the
    # normal path threads override: false (no bypass).
    out = run_cli(%w[task-a task-b], call: "merge", setup: MERGE_STUB)
    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "override: false", "a normal merge threads NO bypass"
  end

  # --- the per-release ASSEMBLER/DEPLOYER conductor claim, at RUNTIME -----------
  # These drive bin/release IN A SUBPROCESS with conductor_claim STUBBED, so they prove
  # the runtime stand-down the source-ordering wiring test can only assert structurally.

  # FIX 1 — `merge` runs the same assembler-lane promote+sweep prepare guards. A held
  # assembler claim must stand merge down BEFORE the (irreversible) promote runs.
  def test_merge_stands_down_before_the_promote_when_the_assembler_claim_is_held
    setup = MERGE_STUB + %(\ndef conductor_claim(*a) = ReleaseClaimCli::STOOD_DOWN\n)
    out = run_cli(%w[task-a], setup: setup,
                  call: "begin; merge; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "a held assembler claim must stand merge down"
    assert_includes out, "held by another live release conductor", "and names the stand-down cause"
    refute_includes out, "NO-ABORT", "merge must not fall through past the claim gate"
    refute_includes out, "PROMOTE-MERGE",
                     "the accepted→release promote must NOT run — merge stands down BEFORE the irreversible mutation"
    refute_includes out, "ADOPT-CALL", "and sweep! (the record) must NOT run either"
  end

  # FIX 2(a) — BEHAVIORAL finalize snapshot-under-claim: finalize must stand down BEFORE
  # it reads its MUTABLE decision snapshot (state/sealed/… → finalize_pending?), or a
  # concurrent finalizer could complete the pending steps in the gap and leave us
  # replaying stale work. The minimal stable slug read (puts({slug: r.slug})) runs
  # pre-claim; the "sealed:" snapshot must NOT be read once we're stood down.
  def test_finalize_stands_down_before_reading_its_mutable_decision_snapshot
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        $stdout.puts("SNAPSHOT-READ") if ruby.include?("sealed:")            # the MUTABLE decision snapshot
        return { "slug" => "rel-x" } if ruby.include?("puts({slug: r.slug}") # the minimal STABLE read
        {}
      end
      def conductor_claim(*a) = ReleaseClaimCli::STOOD_DOWN
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; finalize('rel-x'); puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "a held deployer claim must stand finalize down"
    assert_includes out, "held by another live release conductor", "and names the stand-down cause"
    refute_includes out, "NO-ABORT", "finalize must not fall through past the claim gate"
    refute_includes out, "SNAPSHOT-READ",
                     "finalize must stand down BEFORE reading its mutable decision snapshot — snapshot-under-claim at runtime"
  end

  # FIX B — BEHAVIORAL ship snapshot-under-claim: ship must stand down BEFORE it reads its
  # MUTABLE decision snapshot (repo_plan/state/qa_shas → resuming_member_ship + the assembled
  # gate), or a concurrent ship/finalize could change that state between the read and the
  # deploy. The minimal stable slug read (puts({slug: r.slug})) runs pre-claim; the
  # "repo_plan" snapshot must NOT be read once we're stood down.
  def test_ship_stands_down_before_reading_its_mutable_decision_snapshot
    # CLAIM-CHECK proves ship reached the acquire (PAST the minimal read); its args show the
    # claim is consulted on rel_slug BEFORE any repo_plan read. (ship's rescue re-exits, so
    # the stand-down MESSAGE lands on stderr — the behavioral proof is CLAIM-CHECK before,
    # SNAPSHOT-READ never, NO-ABORT never.)
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        $stdout.puts("SNAPSHOT-READ") if ruby.include?("repo_plan")   # the MUTABLE decision snapshot
        return { "slug" => "rel-x" } if ruby.include?("last_shipped") # the minimal STABLE read
        {}
      end
      def conductor_claim(*a); $stdout.puts("CLAIM-CHECK " + a.join(" ")); ReleaseClaimCli::STOOD_DOWN; end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "CLAIM-CHECK acquire rel-x --role deployer",
                     "ship resolves rel_slug via the minimal read, then CONSULTS the deployer claim"
    assert_includes out, "ABORTED", "a held deployer claim (STOOD_DOWN) stands ship down"
    refute_includes out, "NO-ABORT", "ship must not fall through past the claim gate"
    refute_includes out, "SNAPSHOT-READ",
                     "ship stands down BEFORE reading its mutable decision snapshot (repo_plan) — snapshot-under-claim at runtime"
  end

  # FIX 2(b) — the acquire_conductor_claim! BRANCH TABLE. This is the single runtime
  # hinge for finalize's snapshot-under-claim AND the prepare/merge exclusion; a
  # branch-inversion (swap the STOOD_DOWN/OK arms) or a dropped record would ship the
  # stale-replay / renewer-leak bug green. Pin all three arms behaviorally.
  def test_acquire_conductor_claim_stood_down_arm_aborts_and_records_nothing
    out = run_cli([], setup: %(def conductor_claim(*a) = ReleaseClaimCli::STOOD_DOWN),
                  call: %(begin; acquire_conductor_claim!("deployer", "rel-x"); ) +
                        %(puts("NO-ABORT COUNT=" + held_conductor_claims.size.to_s); ) +
                        %(rescue SystemExit; puts("ABORTED COUNT=" + held_conductor_claims.size.to_s); end))
    assert_includes out, "ABORTED COUNT=0",
                     "STOOD_DOWN must raise SystemExit (stand down) AND record nothing (no renewer to leak)"
    refute_includes out, "NO-ABORT", "the STOOD_DOWN arm must not fall through to recording a claim"
  end

  # A second session's prepare stands down WITH THE HOLDER NAMED. The real
  # conductor_claim seam runs here against a stand-in claim CLI that answers as the
  # board does for a held release (the holder's lane sentence, exit 10), so this
  # pins that the sentence reaches the release log before the abort.
  def test_a_second_sessions_prepare_seam_prints_the_holder_then_stands_down
    sentence = "Mawile (steffon, session …9b57) is assembling rel-x since Oct 8, 01:30 UTC."
    Dir.mktmpdir do |dir|
      stand_in = File.join(dir, "claim_cli.rb")
      File.write(stand_in, <<~RUBY)
        puts("release-claim: 🛑 rel-x assembler already held — STAND DOWN.")
        puts("  #{sentence}")
        exit(10)
      RUBY
      out = run_cli([], setup: %(Object.send(:remove_const, :RELEASE_CLAIM_CLI); RELEASE_CLAIM_CLI = #{stand_in.inspect}),
                    call: %(begin; acquire_conductor_claim!("assembler", "rel-x"); puts("NO-ABORT"); ) +
                          %(rescue SystemExit; puts("ABORTED COUNT=" + held_conductor_claims.size.to_s); end))

      assert_includes out, "    #{sentence}", "the holder's sentence is echoed into the release log"
      assert_operator out.index(sentence), :<, out.index("ABORTED COUNT=0"), "named before the run stands down"
      refute_includes out, "NO-ABORT"
    end
  end

  def test_acquire_conductor_claim_ok_arm_records_exactly_the_held_claim
    out = run_cli([], setup: %(def conductor_claim(*a) = ReleaseClaimCli::OK),
                  call: %(acquire_conductor_claim!("deployer", "rel-x"); c = held_conductor_claims; ) +
                        %(puts("COUNT=" + c.size.to_s); puts("SLUG=" + c.first[:slug].to_s); puts("ROLE=" + c.first[:role].to_s)))
    assert_includes out, "COUNT=1",
                     "an OK acquire records EXACTLY one held claim — a dropped record leaks the renewer (no release ever fires)"
    assert_includes out, "SLUG=rel-x"
    assert_includes out, "ROLE=deployer"
  end

  def test_acquire_conductor_claim_fail_open_arms_never_raise_and_hold_nothing
    [%(def conductor_claim(*a) = nil), %(def conductor_claim(*a) = ReleaseClaimCli::CANT_RUN)].each do |stub|
      out = run_cli([], setup: stub,
                    call: %(acquire_conductor_claim!("deployer", "rel-x"); ) +
                          %(puts("FAIL-OPEN COUNT=" + held_conductor_claims.size.to_s)))
      assert_includes out, "FAIL-OPEN COUNT=0",
                       "a fail-open acquire (nil/CANT_RUN) never raises and holds nothing — a claim outage never wedges a release"
    end
  end

  # --- batch_sweep_ruby / batch_resolve_ruby: pure snippet builders ---------
  # These build the ONE-shot conductor snippets the batched merge runs; unit-test
  # them directly (eval_helper) so the single-call guarantee + slug embedding are
  # pinned independent of the orchestration.

  def test_batch_sweep_ruby_embeds_every_slug_in_one_runner_snippet
    out = eval_helper(%(batch_sweep_ruby(["task-a", "task-b", "task-c"])))
    assert_includes out, "task-a"
    assert_includes out, "task-b"
    assert_includes out, "task-c"
    assert_includes out, "Release::Conductor.sweep!", "the snippet drives sweep!"
    assert_equal 1, out.scan("puts(").size, "the snippet emits exactly ONE JSON line for the whole batch"
  end

  def test_batch_sweep_ruby_threads_the_override_flag
    assert_includes eval_helper(%(batch_sweep_ruby(["task-a"]))), "override: false",
                    "sweep defaults to NO override"
    assert_includes eval_helper(%(batch_sweep_ruby(["task-a"], override: true))), "override: true",
                    "the audited bypass threads into the sweep snippet"
  end

  def test_batch_resolve_ruby_embeds_every_slug_and_reads_one_line
    out = eval_helper(%(batch_resolve_ruby(["task-a", "task-b"])))
    assert_includes out, "task-a"
    assert_includes out, "task-b"
    assert_includes out, "devops_url", "the resolve snippet reads each task's PR url"
    assert_equal 1, out.scan("puts(").size, "the resolve snippet emits ONE JSON line for the batch"
  end

  # THE FIELDS WITHOUT WHICH MERGE'S GUARDS CANNOT FIRE. This snippet crosses a
  # process boundary (it runs on the board), so the string IS the interface — and
  # the whole blocker was an interface omission, not a logic error: with no
  # `repos`/`pr_urls` on the row, Release::SweepPlan.normalize falls back to
  # `[row["repo"]]`, repo_coverage_gap's `size < 2` guard passes every row, and
  # `plan["blocked"]` is structurally always empty however correct the guard is.
  def test_batch_resolve_ruby_emits_the_full_release_identity_per_task
    out = eval_helper(%(batch_resolve_ruby(["task-a"])))

    assert_includes out, "release_repos", "the resolve reads EVERY repo the task names"
    assert_includes out, "release_pr_urls", "…and the PR url recorded per repo"
    assert_includes out, "repos:", "both ride the emitted row"
    assert_includes out, "pr_urls:"
    assert_equal 1, out.scan("puts(").size, "still ONE JSON line for the batch"
  end

  def test_batch_sweep_ruby_validates_members_inside_a_transaction
    # merge's record write was the ONE sweep path with no member validation behind
    # it; prepare's twin (batch_sweep_with_plan_ruby) has always had both.
    out = eval_helper(%(batch_sweep_ruby(["task-a"])))

    assert_includes out, "Release::Conductor.validate_members!", "the backstop runs on merge's write too"
    assert_includes out, "Release.transaction", "a raise must roll the whole sweep back"
    assert_equal 1, out.scan("puts(").size, "still ONE JSON line for the batch"
  end

  def test_batch_resolve_ruby_runs_the_review_gate_screen
    out = eval_helper(%(batch_resolve_ruby(["task-a"], override: true)))
    assert_includes out, "screen_merge", "the resolve snippet runs the review-gate screen in the same read"
    assert_includes out, "override: true", "the override flag threads into the screen"
    assert_equal 1, out.scan("puts(").size, "resolve + screen still emit ONE JSON line"
  end

  def test_batch_resolve_ruby_also_reads_the_active_release_for_the_assembler_claim
    # merge takes the assembler claim on the active release slug (or the FORMING
    # sentinel) BEFORE its promote — so the batched resolve read carries Release.current.
    out = eval_helper(%(batch_resolve_ruby(["task-a"])))
    assert_includes out, "Release.current", "the resolve snippet reads the active release for merge's assembler claim"
    assert_includes out, "release:", "and emits it in the JSON so merge can key its claim on the active slug"
    assert_equal 1, out.scan("puts(").size, "still ONE JSON line (the release rides the same read)"
  end
end
