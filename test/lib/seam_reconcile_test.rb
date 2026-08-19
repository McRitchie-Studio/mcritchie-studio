# frozen_string_literal: true

# Pure unit test for SeamReconcile — the seam-anomaly decision with every fact
# INJECTED (no board, no GitHub, no git, no subprocess). The process-level
# behaviour lives in test/lib/devops_reconcile_cli_test.rb.
#
#   ruby -Itest test/lib/seam_reconcile_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../lib/seam_reconcile"

class SeamReconcileTest < Minitest::Test
  def task(slug: "demo-task", stage: "submitted")
    { "slug" => slug, "stage" => stage }
  end

  # --- the three build/review-seam anomalies -----------------------------------

  # A killed bin/ship: PR open + green, no live build claim. Review cannot see
  # this today because claim-next-review only pops `submitted`.
  def test_flags_ship_interrupted_on_a_green_open_pr_with_a_dead_build_claim
    f = SeamReconcile.classify(task(stage: "building"),
                               pr_state: :open, ci: :green, build_claim_live: false)
    assert_equal :ship_interrupted, f.anomaly
    assert_equal "pr-review", f.seam
    assert_equal :report, f.disposition
  end

  def test_a_live_build_claim_is_not_an_anomaly
    assert_nil SeamReconcile.classify(task(stage: "building"),
                                      pr_state: :open, ci: :green, build_claim_live: true)
  end

  # The one deterministic repair: the PR is provably MERGED, so stamping asserts
  # an observed fact rather than guessing.
  def test_flags_stamp_lost_and_marks_it_healable
    f = SeamReconcile.classify(task, pr_state: :merged, merged_state: :unset)
    assert_equal :stamp_lost, f.anomaly
    assert_equal :heal, f.disposition
    assert_includes f.repair, "bin/task merged demo-task accepted"
  end

  def test_flags_verdict_stranded_for_every_dead_armed_state
    SeamReconcile::DEAD_ARMED_STATES.each do |state|
      f = SeamReconcile.classify(task, pr_state: :open, armed: state)
      assert_equal :verdict_stranded, f.anomaly, "expected #{state} to strand a verdict"
      assert_equal :report, f.disposition
    end
  end

  # A pending arm is still live and may yet land — flagging it would cry wolf on
  # every in-flight review.
  def test_a_pending_arm_is_not_stranded
    assert_nil SeamReconcile.classify(task, pr_state: :open, armed: :pending)
  end

  # --- the later seams ---------------------------------------------------------

  def test_flags_merge_never_landed_for_reviewed_without_a_stamp
    f = SeamReconcile.classify(task(stage: "reviewed"), merged_state: :unset)
    assert_equal :merge_never_landed, f.anomaly
    assert_equal "qa-release", f.seam
  end

  def test_flags_sweep_unfinished_for_reviewed_on_release
    f = SeamReconcile.classify(task(stage: "reviewed"), merged_state: :set, merged_value: "release")
    assert_equal :sweep_unfinished, f.anomaly
    assert_equal "production-deploy", f.seam
    # The repair must name the G3 discriminator, because an INTERRUPTED and an
    # ABORTED sweep leave the identical board reading.
    assert_includes f.repair, "G3"
  end

  def test_reviewed_on_accepted_is_healthy
    assert_nil SeamReconcile.classify(task(stage: "reviewed"),
                                      merged_state: :set, merged_value: "accepted")
  end

  # --- THE SAFETY RULE: an unreadable fact is never a clean fact ---------------

  # The defaults are all :unknown, so a caller that could not reach GitHub or the
  # ledger classifies nothing rather than healing on absence.
  def test_bare_evidence_yields_no_finding
    assert_nil SeamReconcile.classify(task)
    assert_nil SeamReconcile.classify(task(stage: "building"))
    assert_nil SeamReconcile.classify(task(stage: "reviewed"))
  end

  # A board that does not serialise `merged` must NOT read as "no stamp".
  def test_unreported_merged_never_classifies
    assert_nil SeamReconcile.classify(task(stage: "reviewed"), merged_state: :unreported)
    assert_nil SeamReconcile.classify(task, pr_state: :merged, merged_state: :unreported)
  end

  # An unreadable PR state must never reach the one healable anomaly.
  def test_unknown_pr_state_cannot_produce_a_heal
    f = SeamReconcile.classify(task, pr_state: :unknown, merged_state: :unset)
    assert_nil f
  end

  def test_no_anomaly_other_than_stamp_lost_is_healable
    assert_equal %i[stamp_lost], SeamReconcile::HEALABLE
    (SeamReconcile::SEAMS.values.flatten - SeamReconcile::HEALABLE).each do |anomaly|
      assert_equal :report, SeamReconcile.disposition(anomaly), "#{anomaly} must not auto-heal"
    end
  end

  # --- terminal stages ---------------------------------------------------------

  def test_terminal_stages_are_out_of_scope
    SeamReconcile::TERMINAL_STAGES.each do |stage|
      assert_nil SeamReconcile.classify(task(stage: stage), pr_state: :merged, merged_state: :unset)
    end
  end

  def test_a_task_without_a_slug_is_skipped
    assert_nil SeamReconcile.classify({ "stage" => "submitted" },
                                      pr_state: :merged, merged_state: :unset)
  end

  # --- seam scoping ------------------------------------------------------------

  # Acceptance: the scan scopes to ONE seam per invocation, so no SOP is handed
  # an anomaly it is not accountable for.
  def test_scan_returns_only_the_anomalies_the_seam_owns
    tasks = [task(slug: "a", stage: "submitted"), task(slug: "b", stage: "reviewed")]
    evidence = {
      "a" => { pr_state: :merged, merged_state: :unset },
      "b" => { merged_state: :unset }
    }

    review = SeamReconcile.scan(tasks, seam: "pr-review", evidence: evidence)
    assert_equal %w[a], review.map(&:slug)

    sweep = SeamReconcile.scan(tasks, seam: "qa-release", evidence: evidence)
    assert_equal %w[b], sweep.map(&:slug)
  end

  def test_scan_on_an_unknown_seam_is_empty
    assert_empty SeamReconcile.scan([task], seam: "not-a-sop", evidence: {})
  end

  def test_scan_tolerates_a_task_with_no_evidence
    assert_empty SeamReconcile.scan([task], seam: "pr-review", evidence: {})
  end

  def test_every_seam_maps_to_a_registered_sop_name
    assert_equal %w[pr-review qa-release production-deploy].sort, SeamReconcile::SEAMS.keys.sort
    SeamReconcile::SEAMS.each_value do |anomalies|
      anomalies.each { |a| assert SeamReconcile::REPAIRS.key?(a), "#{a} has no repair" }
      anomalies.each { |a| assert SeamReconcile::SUMMARIES.key?(a), "#{a} has no summary" }
    end
  end
end
