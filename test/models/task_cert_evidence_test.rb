# frozen_string_literal: true

require "test_helper"

# The board-side half of the machine-owned evidence namespace: EVERY writer of
# devops.checks_run — bin/task's PATCH, the board UI form, a raw API call, a
# console edit — funnels through Task#save, so the preservation guard lives on
# the model. Regression for the G1 false negative: an agent recording its
# tier-tagged test plan AFTER certifying wiped the fingerprint-bound cert
# evidence, and bin/dor-check then reported "full-suite: MISSING" on freshly
# certified code.
class TaskCertEvidenceTest < ActiveSupport::TestCase
  FP = "1512171634558ef1234567890abcdef123456789"
  OLD_FP = "0000000000000000000000000000000000000000"
  FULL = "[full-suite@#{FP}] bin/rails test (782 runs, 0 failures)"
  RUBOCOP = "[rubocop@#{FP}] bin/rubocop (clean)"
  FAST = "[fast-cert@#{FP}] fast cert green: 4 mapped + 3 spine test path(s)"

  def certified_task(checks: [FULL, RUBOCOP])
    Task.create!(
      title: "Cert Evidence Guard",
      stage: "building",
      metadata: { "devops" => { "kind" => "bug", "shape" => "backend", "checks_run" => checks } }
    )
  end

  test "[unit] a checks_run update preserves machine-written cert evidence" do
    task = certified_task

    # Exactly what `bin/task update <slug> --checks "[unit] ..." --checks "[integration] ..."`
    # sends: the whole devops hash with checks_run REPLACED by the author's lines.
    task.update!(metadata: { "devops" => task.devops.merge(
      "checks_run" => ["[unit] bin/rails test test/models", "[integration] bin/rails test test/controllers"]
    ) })

    checks = task.reload.devops_checks_run
    assert_includes checks, FULL, "the full-suite cert evidence was destroyed by an author --checks update"
    assert_includes checks, RUBOCOP, "the rubocop cert evidence was destroyed by an author --checks update"
    assert_includes checks, "[unit] bin/rails test test/models"
    assert_includes checks, "[integration] bin/rails test test/controllers"
  end

  test "[unit] fast-cert evidence survives a checks_run update" do
    task = certified_task(checks: [FAST, "[unit] old plan"])

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => ["[unit] new plan"]) })

    assert_equal ["[unit] new plan", FAST], task.reload.devops_checks_run
  end

  test "[unit] a cert writer supersedes the lanes it supplies" do
    task = certified_task(checks: ["[unit] plan",
                                   "[full-suite@#{OLD_FP}] bin/rails test (781 runs, 0 failures)",
                                   "[rubocop@#{OLD_FP}] bin/rubocop (clean)"])

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => ["[unit] plan", FULL, RUBOCOP]) })

    checks = task.reload.devops_checks_run
    assert_equal ["[unit] plan", FULL, RUBOCOP], checks
    refute(checks.any? { |line| line.include?(OLD_FP) }, "a re-cert must replace its own stale lines")
  end

  test "[unit] author lines are still replaced cleanly" do
    task = certified_task(checks: ["[unit] stale plan", FULL])

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => ["[unit] fresh plan"]) })

    assert_equal ["[unit] fresh plan", FULL], task.reload.devops_checks_run
  end

  test "[unit] clearing checks_run cannot take the cert down with it" do
    task = certified_task(checks: ["[unit] plan", FULL, RUBOCOP])

    task.update!(metadata: { "devops" => task.devops.merge("checks_run" => []) })

    assert_equal [FULL, RUBOCOP], task.reload.devops_checks_run
  end

  test "[unit] a save that never touches devops leaves the evidence alone" do
    task = certified_task(checks: ["[unit] plan", FULL])

    task.update!(title: "Cert Evidence Guard Two")

    assert_equal ["[unit] plan", FULL], task.reload.devops_checks_run
  end
end
