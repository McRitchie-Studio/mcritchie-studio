require "test_helper"

# [unit] Ci::CheckProgress — the pure fold from a GitHub check-runs payload into
# the passed/total/state datum the progress bar draws. No network, no DB.
class Ci::CheckProgressTest < ActiveSupport::TestCase
  def check_run(status:, conclusion: nil, name: nil, started_at: nil, completed_at: nil)
    { "status" => status, "conclusion" => conclusion, "name" => name,
      "started_at" => started_at, "completed_at" => completed_at }
  end

  test "[unit] folds a mixed payload into passed / failed / pending counts" do
    progress = Ci::CheckProgress.from_check_runs([
      check_run(status: "completed", conclusion: "success"),
      check_run(status: "completed", conclusion: "success"),
      check_run(status: "completed", conclusion: "skipped"),  # skip counts as passed
      check_run(status: "completed", conclusion: "neutral"),  # neutral counts as passed
      check_run(status: "in_progress"),                       # pending
      check_run(status: "queued")                             # pending
    ])

    assert_equal 4, progress.passed
    assert_equal 0, progress.failed
    assert_equal 2, progress.pending
    assert_equal 6, progress.total
  end

  test "[unit] a failure outranks in-flight checks and sets state red" do
    progress = Ci::CheckProgress.from_check_runs([
      check_run(status: "completed", conclusion: "success"),
      check_run(status: "completed", conclusion: "failure"),
      check_run(status: "in_progress")
    ])

    assert_equal 1, progress.passed
    assert_equal 1, progress.failed
    assert_equal 1, progress.pending
    assert_equal :red, progress.state
    assert progress.red?
  end

  test "[unit] every failing conclusion buckets as failed" do
    %w[failure timed_out action_required startup_failure stale cancelled].each do |conclusion|
      progress = Ci::CheckProgress.from_check_runs([check_run(status: "completed", conclusion: conclusion)])
      assert_equal 1, progress.failed, "#{conclusion} should count as failed"
      assert_equal :red, progress.state
    end
  end

  test "[unit] an unknown conclusion degrades to pending, never a phantom pass" do
    progress = Ci::CheckProgress.from_check_runs([check_run(status: "completed", conclusion: "brand_new_state")])
    assert_equal 0, progress.passed
    assert_equal 0, progress.failed
    assert_equal 1, progress.pending
    assert_equal :pending, progress.state
  end

  test "[unit] all-passed run is green with a full bar" do
    progress = Ci::CheckProgress.from_check_runs(Array.new(8) { check_run(status: "completed", conclusion: "success") })
    assert_equal :green, progress.state
    assert progress.green?
    assert_in_delta 1.0, progress.ratio, 0.001
    assert_equal 100, progress.percent
    assert_equal "8 / 8", progress.fraction_label
  end

  test "[unit] a partial run reports the right fraction and percent" do
    progress = Ci::CheckProgress.new(passed: 3, failed: 0, pending: 5)
    assert_equal 8, progress.total
    assert_equal :pending, progress.state
    assert_equal "3 / 8", progress.fraction_label
    assert_equal 38, progress.percent # 3/8 = 37.5 -> 38
  end

  test "[unit] blank is absent, draws no bar, and divides safely" do
    blank = Ci::CheckProgress.blank
    assert_not blank.present?
    assert blank.blank?
    assert_equal :none, blank.state
    assert_equal 0, progress_percent(blank)
    assert_equal 0.0, blank.ratio
  end

  test "[unit] an empty payload is blank, not an error" do
    progress = Ci::CheckProgress.from_check_runs([])
    assert_not progress.present?
    assert_equal :none, progress.state
  end

  # ── per-check data + symbolic threshold (v1.2: one glyph per check) ──────────

  test "[unit] from_check_runs keeps each check's state and name for the symbolic row" do
    progress = Ci::CheckProgress.from_check_runs([
      { "status" => "completed", "conclusion" => "success", "name" => "lint" },
      { "status" => "completed", "conclusion" => "failure", "name" => "test" },
      { "status" => "in_progress", "name" => "playwright (1)" }
    ])

    assert_equal 3, progress.checks.size, "one Check per run, mapping 1:1 to the CI jobs"
    assert_equal %i[passed failed pending], progress.checks.map(&:state)
    assert_equal ["lint", "test", "playwright (1)"], progress.checks.map(&:name)
    assert_equal 1, progress.passed
    assert_equal 1, progress.failed
    assert_equal 1, progress.pending
  end

  test "[unit] count-only input synthesizes nameless checks totalling the counts" do
    progress = Ci::CheckProgress.new(passed: 2, failed: 1, pending: 3)

    assert_equal 6, progress.checks.size
    assert_equal 2, progress.checks.count(&:passed?)
    assert_equal 1, progress.checks.count(&:failed?)
    assert_equal 3, progress.checks.count(&:pending?)
    assert_nil progress.checks.first.name, "the fixture seam has no per-check identity"
  end

  # ── the meter's draw order + clock (one row, marks inside the rail) ────────────

  test "[unit] ordered_checks puts failures left, running in the middle, passes right" do
    progress = Ci::CheckProgress.from_check_runs([
      check_run(status: "completed", conclusion: "success", name: "b-pass"),
      check_run(status: "in_progress", name: "c-run"),
      check_run(status: "completed", conclusion: "failure", name: "z-fail"),
      check_run(status: "completed", conclusion: "success", name: "a-pass")
    ])

    assert_equal %i[failed pending passed passed], progress.ordered_checks.map(&:state),
      "a check migrates left when it goes red and right when it goes green"
    assert_equal %w[z-fail c-run a-pass b-pass], progress.ordered_checks.map(&:name),
      "severity first, then name — so the order is stable across re-renders"
  end

  test "[unit] a cap can only ever drop surplus PASSES, never a failure" do
    runs = Array.new(20) { |i| check_run(status: "completed", conclusion: "success", name: "pass-#{i}") }
    runs << check_run(status: "completed", conclusion: "failure", name: "zz-lint")
    progress = Ci::CheckProgress.from_check_runs(runs)

    assert_equal :failed, progress.ordered_checks.first(14).map(&:state).first,
      "the failing check survives the cap even though its name sorts last"
  end

  test "[unit] resolved_percent counts failures as finished work; percent counts only passes" do
    progress = Ci::CheckProgress.new(passed: 8, failed: 1, pending: 1)

    assert_equal 9, progress.resolved
    assert_equal 90, progress.resolved_percent, "9 of 10 checks have settled — the bar is nearly full"
    assert_equal 80, progress.percent, "the pass-only ratio is the OTHER number, unchanged"
  end

  test "[unit] the clock ticks while running and freezes to a duration once settled" do
    started = Time.zone.parse("2026-08-18 10:00:00")
    running = Ci::CheckProgress.from_check_runs([
      check_run(status: "completed", conclusion: "success", started_at: started, completed_at: started + 30),
      check_run(status: "in_progress", started_at: started + 5)
    ], run_started_at: started)

    assert running.running?
    assert_equal started, running.started_at
    assert_nil running.finished_at, "one check is still going — the run has not finished"
    assert_nil running.duration_seconds, "so there is no duration yet, only elapsed time"

    settled = Ci::CheckProgress.from_check_runs([
      check_run(status: "completed", conclusion: "success", started_at: started, completed_at: started + 30),
      check_run(status: "completed", conclusion: "failure", started_at: started + 5, completed_at: started + 252)
    ], run_started_at: started)

    assert_not settled.running?
    assert_equal started + 252, settled.finished_at, "the LAST check to settle ends the run"
    assert_equal 252, settled.duration_seconds
  end

  test "[unit] the RUN's own start outranks the checks' — a late job never redates the run" do
    run_start = Time.zone.parse("2026-08-18 10:00:00")
    progress = Ci::CheckProgress.from_check_runs(
      [check_run(status: "in_progress", started_at: run_start + 90)], run_started_at: run_start
    )

    assert_equal run_start, progress.started_at, "a job queued behind a runner still belongs to an earlier run"
  end

  test "[unit] no ingested timestamps at all -> no clock, never a zero" do
    progress = Ci::CheckProgress.new(passed: 1, failed: 0, pending: 0)

    assert_nil progress.started_at
    assert_nil progress.duration_seconds
  end

  private

  def progress_percent(progress)
    progress.percent
  end
end
