# frozen_string_literal: true

# The release CI gate's ONE automatic re-run (bin/lib/ci_rerun.rb): which red verdicts
# earn it, which never do, and when the re-run counts as the second verdict.
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

  # --- plan ------------------------------------------------------------------

  # [unit] THE FLAKE: a first-attempt red whose failing jobs are all test lanes is re-run.
  def test_a_first_attempt_test_lane_red_earns_one_rerun
    plan = CiRerun.plan(runs: [run_row(40_237_591_268)], jobs_by_run: { 40_237_591_268 => ["test"] })

    assert_equal :rerun, plan[:action]
    assert_equal [40_237_591_268], plan[:run_ids]
    assert_includes plan[:reason], "test lane test failed on attempt 1"
  end

  # [unit] THE RACE: lint and scan_js are not test lanes, but their log is the resolution error.
  def test_a_non_test_job_with_the_gem_resolution_error_earns_one_rerun
    plan = CiRerun.plan(runs: [run_row(40_267_136_223)], jobs_by_run: { 40_267_136_223 => %w[scan_js lint] },
                        log_for: ->(_id) { RACE_LOG })

    assert_equal :rerun, plan[:action]
    assert_includes plan[:reason], "gem-resolution error"
  end

  def test_a_real_lint_failure_is_never_rerun
    plan = CiRerun.plan(runs: [run_row(7)], jobs_by_run: { 7 => %w[lint test] },
                        log_for: ->(_id) { "Offenses: 3" })

    assert_equal :none, plan[:action]
    assert_includes plan[:reason], "lint, which is not a test lane"
  end

  # [unit] NEVER MORE THAN ONE: a run already on attempt 2 is a second red, and it is real.
  def test_a_run_already_rerun_is_never_rerun_again
    plan = CiRerun.plan(runs: [run_row(9, attempt: 2)], jobs_by_run: { 9 => ["test"] })

    assert_equal :none, plan[:action]
    assert_includes plan[:reason], "a second red is real"
  end

  def test_one_ineligible_run_refuses_the_whole_rerun
    runs = [run_row(1), run_row(2, attempt: 2)]
    plan = CiRerun.plan(runs: runs, jobs_by_run: { 1 => ["test"], 2 => ["test"] })

    assert_equal :none, plan[:action], "the gate re-runs every failed run or none"
  end

  def test_cancelled_scheduled_and_jobless_runs_are_not_rerun
    assert_equal :none, CiRerun.plan(runs: [run_row(1, conclusion: "cancelled")], jobs_by_run: { 1 => ["test"] })[:action]
    assert_equal :none, CiRerun.plan(runs: [run_row(1, event: "schedule")], jobs_by_run: { 1 => ["test"] })[:action]
    assert_equal :none, CiRerun.plan(runs: [run_row(1)], jobs_by_run: {})[:action]
    assert_equal :none, CiRerun.plan(runs: [], jobs_by_run: {})[:action]
  end

  def test_a_pure_test_lane_flake_reads_no_log
    reads = 0
    CiRerun.plan(runs: [run_row(1)], jobs_by_run: { 1 => ["test"] }, log_for: ->(_id) { reads += 1 && "" })

    assert_equal 0, reads, "the log read is only for a non-test job"
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
end
