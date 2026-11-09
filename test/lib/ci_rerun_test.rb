# frozen_string_literal: true

# The release CI gate's red-verdict decision (bin/lib/ci_rerun.rb): a red stops and is
# recorded (Alex McRitchie's deterministic-CI ruling, 2026-11-08), except the one named
# infra cause (bundler's gem-resolution error in every failing job), which earns one
# re-run; and when that re-run counts as the second verdict.
#
#   ruby -Itest test/lib/ci_rerun_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/ci_rerun"

class CiRerunTest < Minitest::Test
  SHA = "a" * 40

  def run_row(id, conclusion: "failure", attempt: 1, event: "push", name: "CI", status: "completed", sha: SHA)
    { "id" => id, "name" => name, "conclusion" => conclusion, "run_attempt" => attempt,
      "event" => event, "status" => status, "head_sha" => sha }
  end

  # The 2026-10-26 rantly race, verbatim from run 40267136223.
  RACE_LOG = "scan_js\tSet up Ruby\tYour bundle is locked to studio-engine (0.114.1) from rubygems " \
             "repository https://rubygems.org/ or installed locally, but that version can no longer be " \
             "found in that source. That means the author of studio-engine (0.114.1) has removed it."

  # --- test_lane? -------------------------------------------------------------

  def test_suite_shard_browser_and_aggregate_jobs_are_test_lanes
    ["test", "system-test", "ci / rails (2)", "engine suite (bin/release-check)", "browser lane (playwright)",
     "turf-monster suite vs this engine(shard 1/3)", "mcritchie_studio executed-set", "ci / system",
     "playwright (2)"].each { |name| assert CiRerun.test_lane?(name), "#{name} runs a suite" }
  end

  def test_lint_scan_audit_plan_and_resolve_jobs_are_not_test_lanes
    ["lint", "scan_ruby", "scan_js", "ci / static", "ci / rails_plan", "Resolve consumer commits",
     "bundler-audit", "", "ci / javascript"].each { |name| refute CiRerun.test_lane?(name), "#{name.inspect} is not a suite" }
  end

  def test_the_resolution_error_matches_the_race_verbatim_and_not_an_ordinary_failure
    assert CiRerun.resolution_error?(RACE_LOG)
    assert CiRerun.resolution_error?("Could not find studio-engine-0.114.1 in any of the sources")
    refute CiRerun.resolution_error?("Offenses: app/models/x.rb:3:1 Layout/IndentationWidth")
    refute CiRerun.resolution_error?(nil)
  end

  # rel-20261029-00560a, voicebox run 40938649188 attempt 1, verbatim from
  # `gh run view --attempt 1 --log-failed`: bundler's 80-column wrap splits the
  # phrase across lines, each behind its job/step/timestamp prefix. The joined
  # RACE_LOG above matched; this real shape did not, and the ship stopped twice.
  WRAPPED_LOG = <<~LOG
    scan_ruby\tSet up Ruby\t2026-10-29T19:17:13.4991505Z Fetching gem metadata from https://rubygems.org/........
    scan_ruby\tSet up Ruby\t2026-10-29T19:17:13.5102436Z Your bundle is locked to studio-engine (0.119.0) from rubygems repository
    scan_ruby\tSet up Ruby\t2026-10-29T19:17:13.5103601Z https://rubygems.org/ or installed locally, but that version can no longer be
    scan_ruby\tSet up Ruby\t2026-10-29T19:17:13.5127697Z found in that source. That means the author of studio-engine (0.119.0) has
    scan_ruby\tSet up Ruby\t2026-10-29T19:17:13.5128870Z removed it. You'll need to update your bundle to a version other than
  LOG

  def test_the_resolution_error_matches_across_bundlers_line_wrap
    assert CiRerun.resolution_error?(WRAPPED_LOG)
    # The job-log API shape (no job/step columns), as the alex-build static job printed it.
    assert CiRerun.resolution_error?(WRAPPED_LOG.gsub("scan_ruby\tSet up Ruby\t", ""))
    refute CiRerun.resolution_error?(WRAPPED_LOG.sub("can no longer be", "is"))
  end

  def test_a_wrapped_race_in_a_static_job_earns_the_infra_rerun
    decision = CiRerun.plan(runs: [run_row(40_938_601_557)], jobs_by_run: { 40_938_601_557 => ["ci / static"] },
                            log_for: ->(_id) { WRAPPED_LOG })

    assert_equal :rerun, decision[:action], decision[:reason]
    assert_equal "infra", decision[:cause]
  end

  # --- plan ------------------------------------------------------------------

  MINITEST_LOG = "test\tRun tests\t2026-11-08T15:01:02.0000000Z Failure:\n" \
                 "test\tRun tests\t2026-11-08T15:01:02.1000000Z ProductionSslTest#test_redirect [test/integration/production_ssl_test.rb:43]:\n" \
                 "test\tRun tests\t2026-11-08T15:01:02.2000000Z bin/rails test test/integration/production_ssl_test.rb:43\n"

  # [unit] THE RULING: a first-attempt test-lane red is a defect with a cause, never a
  # retry. It stops, and the plan carries the run id, job and spec for the record.
  def test_a_first_attempt_test_lane_red_stops_and_names_run_job_and_spec
    plan = CiRerun.plan(runs: [run_row(40_237_591_268)], jobs_by_run: { 40_237_591_268 => ["test"] },
                        log_for: ->(_id) { MINITEST_LOG })

    assert_equal :stop, plan[:action]
    refute plan.key?(:run_ids), "nothing to re-run"
    assert_includes plan[:reason], "test lane test failed with no gem-resolution error"
    failure = plan[:failures].first
    assert_equal 40_237_591_268, failure["run_id"]
    assert_equal ["test"], failure["jobs"]
    assert_equal ["test"], failure["test_lanes"]
    assert_equal ["test/integration/production_ssl_test.rb:43"], failure["specs"]
  end

  # [unit] THE RACE: lint and scan_js died on the resolution error → the one infra re-run.
  def test_a_non_test_job_with_the_gem_resolution_error_earns_the_infra_rerun
    plan = CiRerun.plan(runs: [run_row(40_267_136_223)], jobs_by_run: { 40_267_136_223 => %w[scan_js lint] },
                        log_for: ->(_id) { RACE_LOG })

    assert_equal :rerun, plan[:action]
    assert_equal "infra", plan[:cause]
    assert_equal [40_267_136_223], plan[:run_ids]
    assert_includes plan[:reason], "gem-resolution error"
  end

  # [unit] A test lane whose own log carries the resolution error is the race too.
  def test_a_test_lane_that_died_on_the_resolution_error_is_infra
    log = WRAPPED_LOG.gsub("scan_ruby\t", "test\t")
    plan = CiRerun.plan(runs: [run_row(3)], jobs_by_run: { 3 => ["test"] }, log_for: ->(_id) { log })

    assert_equal :rerun, plan[:action], plan[:reason]
  end

  # [unit] One job on the race, another on an assertion: the assertion is a finding.
  # The test lane cannot borrow the scan job's resolution error.
  def test_a_race_in_one_job_does_not_cover_a_real_failure_in_another
    log = WRAPPED_LOG + MINITEST_LOG
    plan = CiRerun.plan(runs: [run_row(4)], jobs_by_run: { 4 => %w[scan_ruby test] }, log_for: ->(_id) { log })

    assert_equal :stop, plan[:action], plan[:reason]
    assert_includes plan[:reason], "test lane test failed with no gem-resolution error"
    assert_equal ["test/integration/production_ssl_test.rb:43"], plan[:failures].first["specs"]
  end

  def test_a_real_lint_failure_stops
    plan = CiRerun.plan(runs: [run_row(7)], jobs_by_run: { 7 => %w[lint test] },
                        log_for: ->(_id) { "Offenses: 3" })

    assert_equal :stop, plan[:action]
    assert_includes plan[:reason], "jobs lint, test failed with no gem-resolution error"
  end

  # [unit] NEVER MORE THAN ONE: a run already on attempt 2 was re-run; its red is real.
  def test_a_run_already_rerun_is_never_rerun_again
    plan = CiRerun.plan(runs: [run_row(9, attempt: 2)], jobs_by_run: { 9 => ["scan_js"] }, log_for: ->(_id) { RACE_LOG })

    assert_equal :stop, plan[:action]
    assert_includes plan[:reason], "this red is real"
  end

  def test_one_ineligible_run_stops_the_whole_verdict
    runs = [run_row(1), run_row(2, attempt: 2)]
    plan = CiRerun.plan(runs: runs, jobs_by_run: { 1 => ["lint"], 2 => ["lint"] }, log_for: ->(_id) { RACE_LOG })

    assert_equal :stop, plan[:action], "the gate re-runs every failed run or none"
    assert_equal [1, 2], plan[:failures].map { |f| f["run_id"] }, "every failed run is on the record"
  end

  def test_cancelled_scheduled_dispatched_and_jobless_runs_stop
    race = ->(_id) { RACE_LOG }
    assert_equal :stop, CiRerun.plan(runs: [run_row(1, conclusion: "cancelled")], jobs_by_run: { 1 => ["lint"] }, log_for: race)[:action]
    assert_equal :stop, CiRerun.plan(runs: [run_row(1, event: "schedule")], jobs_by_run: { 1 => ["lint"] }, log_for: race)[:action]
    deploy = CiRerun.plan(runs: [run_row(1, event: "workflow_dispatch")], jobs_by_run: { 1 => ["deploy"] }, log_for: race)
    assert_equal :stop, deploy[:action], "a dispatched deploy run is never re-run, even on the resolution error"
    assert_equal :rerun, CiRerun.plan(runs: [run_row(1, event: "pull_request")], jobs_by_run: { 1 => ["lint"] },
                                      log_for: race)[:action]
    assert_equal :stop, CiRerun.plan(runs: [run_row(1)], jobs_by_run: {}, log_for: race)[:action]
    assert_equal :stop, CiRerun.plan(runs: [], jobs_by_run: {})[:action]
  end

  # --- the record -------------------------------------------------------------

  def test_specs_in_names_minitest_rspec_and_playwright_locations
    log = "bin/rails test test/models/gadget_test.rb:12\nrspec ./spec/models/user_spec.rb:7 # User works\n" \
          "  1) [chromium] › e2e/survey_flow.spec.js:158:5 › survey › submits\nOffenses: app/models/x.rb:3:1\n"

    assert_equal ["test/models/gadget_test.rb:12", "spec/models/user_spec.rb:7", "e2e/survey_flow.spec.js:158"],
                 CiRerun.specs_in(log)
    assert_equal [], CiRerun.specs_in(nil)
  end

  def test_red_record_names_run_jobs_specs_and_the_next_step
    failures = [{ "run_id" => 11, "name" => "CI", "attempt" => 1, "jobs" => ["test"],
                  "specs" => ["test/integration/production_ssl_test.rb:43"] }]
    line = CiRerun.red_record("rantly", "ccccccc", failures, "CI (run 11): test lane test failed")

    assert_includes line, "CI RED rantly@ccccccc"
    assert_includes line, "run 11 (CI, attempt 1): jobs test; specs test/integration/production_ssl_test.rb:43"
    assert_includes line, "fix it forward through a task, re-run the cycle"
    assert_includes CiRerun.red_record("rantly", "c", [], "none"), "no failed run read"
  end

  # --- failed_runs / settled? ---------------------------------------------------

  def test_failed_runs_keeps_completed_failures_on_this_sha_only
    rows = [run_row(1), run_row(2, conclusion: "success"), run_row(3, status: "in_progress", conclusion: ""),
            run_row(4, sha: "b" * 40), run_row(5, conclusion: "timed_out")]

    assert_equal [1, 5], CiRerun.failed_runs(rows, SHA).map { |r| r["id"] }
  end

  # [unit] The first attempt's red is still on the SHA right after the re-run is
  # requested; it must not be read as the second verdict.
  def test_a_rerun_counts_only_once_a_later_attempt_has_completed
    refute CiRerun.settled?([run_row(1, attempt: 1)], [1]), "GitHub has not picked the re-run up yet"
    refute CiRerun.settled?([run_row(1, attempt: 2, status: "in_progress")], [1]), "the re-run is still running"
    refute CiRerun.settled?([], [1]), "an unreadable run is not settled"
    assert CiRerun.settled?([run_row(1, attempt: 2, conclusion: "failure")], [1])
  end

  # --- in_progress? -----------------------------------------------------------

  # [unit] 2026-10-27: one job red, its run still going. The red is early, not final.
  def test_an_unfinished_commit_run_on_the_sha_is_in_progress
    assert CiRerun.in_progress?([run_row(1, status: "in_progress", conclusion: nil)], SHA)
    assert CiRerun.in_progress?([run_row(1), run_row(2, status: "queued", conclusion: nil)], SHA)
    refute CiRerun.in_progress?([run_row(1)], SHA)
    refute CiRerun.in_progress?([run_row(1, status: "in_progress", sha: "b" * 40)], SHA), "another SHA's run"
    refute CiRerun.in_progress?([run_row(1, status: "in_progress", event: "schedule")], SHA),
           "a nightly does not test the commit and must not hold the gate"
    refute CiRerun.in_progress?([], SHA)
  end
end
