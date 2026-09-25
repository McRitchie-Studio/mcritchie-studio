# frozen_string_literal: true

require "test_helper"

# The board-side half of the machine-owned evidence namespace: EVERY writer of
# devops.checks_run — bin/task's PATCH, the board UI form, a raw API call, a
# console edit — funnels through Task#save, so the preservation guard lives on
# the model. The one lane left is the `test-only` shape's `[control@<fp>]` stamp
# (bin/control-check); an agent recording its tier-tagged test plan AFTER the
# control ran must not wipe it, or bin/dor-check reports it MISSING on code that
# was just replayed.
class TaskCertEvidenceTest < ActiveSupport::TestCase
  FP = "1512171634558ef1234567890abcdef123456789"
  OLD_FP = "0000000000000000000000000000000000000000"
  CONTROL = "[control@#{FP}] NECESSARY — replayed test/models/a_test.rb"
  HUB_CONTROL = "[control@#{FP}:mcritchie-studio] NECESSARY — replayed test/models/a_test.rb"
  TURF_CONTROL = "[control@#{OLD_FP}:turf-monster] NECESSARY — replayed test/models/b_test.rb"

  def stamped_task(checks: [CONTROL])
    Task.create!(
      title: "Control Stamp Guard",
      stage: "building",
      metadata: { "devops" => { "kind" => "chore", "shape" => "test-only", "checks_run" => checks } }
    )
  end

  test "[unit] a two-repo task keeps a stamp for BOTH repos" do
    task = Task.create!(
      title: "Two Repo Stamp Guard",
      stage: "building",
      metadata: { "devops" => { "kind" => "chore", "shape" => "test-only",
                                "repositories" => %w[mcritchie-studio turf-monster],
                                "checks_run" => ["[unit] plan"] } }
    )

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => ["[unit] plan", HUB_CONTROL]) })
    task.update!(metadata: { "devops" => task.reload.devops.merge("checks_run" => [TURF_CONTROL]) })

    checks = task.reload.devops_checks_run
    assert_includes checks, HUB_CONTROL, "stamping turf destroyed the hub's stamp — the multi-repo bug"
    assert_includes checks, TURF_CONTROL
    assert_includes checks, "[unit] plan", "a pure-evidence write still preserves the author namespace"
  end

  test "[unit] re-running the control for one repo replaces only its own line" do
    task = stamped_task(checks: ["[unit] plan", HUB_CONTROL, TURF_CONTROL])
    fresh_hub = "[control@#{OLD_FP}:mcritchie-studio] NECESSARY — replayed test/models/a_test.rb"

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => [fresh_hub]) })

    checks = task.reload.devops_checks_run
    assert_includes checks, fresh_hub
    refute_includes checks, HUB_CONTROL, "a re-run must still supersede its OWN repo's stale line"
    assert_includes checks, TURF_CONTROL, "a re-run for one repo must not touch the other repo's stamp"
  end

  test "[unit] a checks_run update preserves the machine-written control stamp" do
    task = stamped_task

    # Exactly what `bin/task update <slug> --checks "[unit] ..." --checks "[integration] ..."`
    # sends: the whole devops hash with checks_run REPLACED by the author's lines.
    task.update!(metadata: { "devops" => task.devops.merge(
      "checks_run" => ["[unit] bin/rails test test/models", "[integration] bin/rails test test/controllers"]
    ) })

    checks = task.reload.devops_checks_run
    assert_includes checks, CONTROL, "the control stamp was destroyed by an author --checks update"
    assert_includes checks, "[unit] bin/rails test test/models"
    assert_includes checks, "[integration] bin/rails test test/controllers"
  end

  test "[unit] a re-run supersedes the stamp it supplies" do
    task = stamped_task(checks: ["[unit] plan", "[control@#{OLD_FP}] NO-SIGNAL — replayed test/models/a_test.rb"])

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => ["[unit] plan", CONTROL]) })

    checks = task.reload.devops_checks_run
    assert_equal ["[unit] plan", CONTROL], checks
    refute(checks.any? { |line| line.include?(OLD_FP) }, "a re-run must replace its own stale stamp")
  end

  test "[unit] author lines are still replaced cleanly" do
    task = stamped_task(checks: ["[unit] stale plan", CONTROL])

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => ["[unit] fresh plan"]) })

    assert_equal ["[unit] fresh plan", CONTROL], task.reload.devops_checks_run
  end

  test "[unit] a pure-evidence write cannot wipe the tier tags" do
    task = stamped_task(checks: ["[unit] bin/rails test test/models",
                                 "[integration] bin/rails test test/controllers"])

    # Exactly what bin/control-check sends: the stamp alone.
    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => [CONTROL]) })

    checks = task.reload.devops_checks_run
    assert_includes checks, "[unit] bin/rails test test/models", "a pure-evidence write wiped the builder's tier tags"
    assert_includes checks, "[integration] bin/rails test test/controllers"
    assert_includes checks, CONTROL
  end

  test "[unit] clearing checks_run cannot take the stamp down with it" do
    task = stamped_task(checks: ["[unit] plan", CONTROL])

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => []) })

    assert_equal [CONTROL], task.reload.devops_checks_run
  end

  test "[unit] a save that never touches devops leaves the stamp alone" do
    task = stamped_task(checks: ["[unit] plan", CONTROL])

    task.update!(title: "Control Stamp Guard Two")

    assert_equal ["[unit] plan", CONTROL], task.reload.devops_checks_run
  end

  test "[unit] a leftover cert receipt is author prose and clears with the author's lines" do
    receipt = "[fast-cert@#{OLD_FP}] fast cert green: 4 mapped"
    task = stamped_task(checks: [receipt, "[unit] old plan", CONTROL])

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => ["[unit] new plan"]) })

    assert_equal ["[unit] new plan", CONTROL], task.reload.devops_checks_run,
                 "the retired receipts (/tasks/retire-local-cert-evidence) are no longer machine-owned"
  end
end
