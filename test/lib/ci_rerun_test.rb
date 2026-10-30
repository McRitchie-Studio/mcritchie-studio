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

  def test_a_wrapped_race_in_a_static_job_earns_the_rerun
    decision = CiRerun.plan(runs: [run_row(40_938_601_557)], jobs_by_run: { 40_938_601_557 => ["ci / static"] },
                            log_for: ->(_id) { WRAPPED_LOG })

    assert_equal :rerun, decision[:action], decision[:reason]
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
    deploy = CiRerun.plan(runs: [run_row(1, event: "workflow_dispatch")], jobs_by_run: { 1 => ["deploy"] },
                          log_for: ->(_id) { "is locked to studio-engine (0.1.0) ... can no longer be found in that source" })
    assert_equal :none, deploy[:action], "a dispatched deploy run is never re-run, even on the resolution error"
    assert_equal :rerun, CiRerun.plan(runs: [run_row(1, event: "pull_request")], jobs_by_run: { 1 => ["test"] })[:action]
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

  # --- the re-lock rule (relock_only:) --------------------------------------

  # [unit] THE RE-LOCK GATE: the commit differs from the QA-green tree in the lock
  # alone, so a first-attempt red in ANY job (here lint, with no resolution error in
  # its log) earns the one re-run, and its second red is refused.
  def test_the_relock_only_gate_reruns_a_failed_job_once_and_refuses_a_second_time
    first = CiRerun.plan(runs: [run_row(5)], jobs_by_run: { 5 => ["lint"] },
                         log_for: ->(_id) { "Offenses: 1" }, relock_only: true)
    assert_equal :rerun, first[:action]
    assert_equal [5], first[:run_ids]
    assert_includes first[:reason], "re-lock commit"

    second = CiRerun.plan(runs: [run_row(5, attempt: 2)], jobs_by_run: { 5 => ["lint"] }, relock_only: true)
    assert_equal :none, second[:action], "a re-lock red after the re-run is real"
    assert_includes second[:reason], "a second red is real"

    ordinary = CiRerun.plan(runs: [run_row(5)], jobs_by_run: { 5 => ["lint"] }, log_for: ->(_id) { "Offenses: 1" })
    assert_equal :none, ordinary[:action], "off a re-lock commit, a lint red stays a finding"
  end

  def test_the_relock_rule_still_never_reruns_a_cancelled_or_dispatched_run
    assert_equal :none, CiRerun.plan(runs: [run_row(1, conclusion: "cancelled")], jobs_by_run: { 1 => ["x"] },
                                     relock_only: true)[:action]
    assert_equal :none, CiRerun.plan(runs: [run_row(2, event: "workflow_dispatch")], jobs_by_run: { 2 => ["x"] },
                                     relock_only: true)[:action]
  end

  def test_relock_only_diff_is_gemfile_and_gemfile_lock_alone
    assert CiRerun.relock_only_diff?(["Gemfile.lock\n"])
    assert CiRerun.relock_only_diff?(%w[Gemfile Gemfile.lock])
    refute CiRerun.relock_only_diff?(%w[Gemfile.lock app/models/task.rb]), "code rode along"
    refute CiRerun.relock_only_diff?([]), "no diff vouches for nothing"
    refute CiRerun.relock_only_diff?(["engine/Gemfile.lock"])
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
