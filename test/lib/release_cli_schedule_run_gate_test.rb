# frozen_string_literal: true

# The release CI gate and schedule-triggered runs (task ui-budget-report-never-gates):
# a nightly report on main's head never holds a ship, and a red push run still does.
# Same harness and RELEASE_CI_STATUS seam as release_cli_pre_qa_gate_test.rb; the
# CiStatus half lives in ci_status_schedule_exemption_test.rb. Run directly:
#   ruby -Itest test/lib/release_cli_schedule_run_gate_test.rb

require_relative "release_cli_harness"

class ReleaseCliScheduleRunGateTest < ReleaseCliHarness
  # [integration] A NIGHTLY DOES NOT JUDGE THE COMMIT (task ui-budget-report-never-gates).
  # The scheduled UI Budget run attached a red check to main's head and blocked a
  # cleared production ship. A RAW payload carrying the SHA's workflow runs proves the
  # red run was schedule-triggered, so the gate passes on the green push CI beside it.
  def schedule_payload(schedule_conclusion, push_conclusion)
    JSON.generate(
      "total_count" => 2,
      "check_runs" => [
        { "name" => "budget", "status" => "completed", "conclusion" => schedule_conclusion,
          "head_sha" => GATE_SHA, "check_suite" => { "id" => 71 } },
        { "name" => "test", "status" => "completed", "conclusion" => push_conclusion,
          "head_sha" => GATE_SHA, "check_suite" => { "id" => 72 } }
      ],
      "workflow_runs" => [
        { "id" => 1, "name" => "UI Budget", "event" => "schedule", "head_sha" => GATE_SHA, "check_suite_id" => 71 },
        { "id" => 2, "name" => "CI", "event" => "push", "head_sha" => GATE_SHA, "check_suite_id" => 72 }
      ]
    )
  end

  def test_pre_qa_gate_ignores_a_red_schedule_run_beside_a_green_push_run
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, schedule_payload("failure", "success")),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "GitHub CI GREEN @ #{GATE_SHA[0, 7]}", out
      assert_includes out, "PASSED"
      refute_includes out, "ABORTED"
    end
  end

  def test_pre_qa_gate_still_fails_closed_on_a_red_push_run_beside_a_schedule_run
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, schedule_payload("failure", "failure")),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", out
      assert_includes out, "GitHub CI called #{GATE_SHA[0, 7]} RED"
      refute_includes out, "PASSED"
    end
  end
end
