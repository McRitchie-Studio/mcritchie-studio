require "test_helper"

# [unit] Ci::CheckProgress — the pure fold from a GitHub check-runs payload into
# the passed/total/state datum the progress bar draws. No network, no DB.
class Ci::CheckProgressTest < ActiveSupport::TestCase
  def check_run(status:, conclusion: nil)
    { "status" => status, "conclusion" => conclusion }
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

  test "[unit] a small suite is symbolic; a large one keeps the numeric bar" do
    eleven = Ci::CheckProgress.from_check_runs(Array.new(11) { check_run(status: "completed", conclusion: "success") })
    twelve = Ci::CheckProgress.from_check_runs(Array.new(12) { check_run(status: "completed", conclusion: "success") })

    assert eleven.symbolic?, "under 12 checks renders one symbol per check"
    assert_not eleven.numeric?
    assert_not twelve.symbolic?, "12+ checks keeps the numeric X / Y bar"
    assert twelve.numeric?
    assert_equal 12, Ci::CheckProgress::SYMBOLIC_THRESHOLD
  end

  test "[unit] a blank datum is neither symbolic nor numeric — it draws nothing" do
    blank = Ci::CheckProgress.blank
    assert_not blank.symbolic?
    assert_not blank.numeric?
  end

  private

  def progress_percent(progress)
    progress.percent
  end
end
