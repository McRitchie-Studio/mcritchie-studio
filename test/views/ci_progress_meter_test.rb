require "test_helper"

# [component] The board card's CI meter (components/_ci_progress_meter) — the one-row
# redesign: the PR number and the run clock in the header, one mark per check INSIDE
# the rail (failures left, running middle, passes right), and a fade instead of a
# silent clip when the suite outruns the cap.
#
# The clock is the part worth pinning hardest, because it has two states that look
# alike in a screenshot and mean opposite things: a LIVE elapsed timer while checks
# are still running, and a FROZEN duration once they have all settled.
class CiProgressMeterTest < ActionView::TestCase
  RUN_START = Time.zone.parse("2026-08-18 10:00:00")

  test "[component] a running suite ticks a LIVE clock off the run's start" do
    render partial: "components/ci_progress_meter",
           locals: { progress: running_progress, label: "PR: 610", test_id: "task-ci-progress" }

    clock = css_select("[data-test='task-ci-progress-clock']").first
    assert_equal "running", clock["data-ci-clock"]
    # data-release-ticker + mode=short is what the installed-once ticker advances every
    # second; data-since is the run start, so the browser and the server agree.
    assert_equal "short", clock["data-mode"]
    assert_equal RUN_START.to_i.to_s, clock["data-since"]
    assert_equal "PR: 610", css_select("[data-test='task-ci-progress-label']").first.text.strip
  end

  test "[component] a settled suite FREEZES to the measured duration, with no ticker" do
    render partial: "components/ci_progress_meter",
           locals: { progress: settled_progress(seconds: 252), label: "PR: 610", test_id: "task-ci-progress" }

    clock = css_select("[data-test='task-ci-progress-clock']").first
    assert_equal "settled", clock["data-ci-clock"]
    assert_nil clock["data-release-ticker"], "a finished run must not keep counting"
    assert_equal "4m", clock.text.strip, "252s -> the single-unit ladder's 4m"
    assert_includes clock["title"], "CI took"
  end

  test "[component] no ingested timestamps -> no clock at all, never a 0s" do
    render partial: "components/ci_progress_meter",
           locals: { progress: Ci::CheckProgress.new(passed: 2, pending: 1), label: "PR: 7", test_id: "task-ci-progress" }

    assert_select "[data-test='task-ci-progress-clock']", 0
    assert_select "[data-test='task-ci-progress-label']", text: "PR: 7"
  end

  test "[component] the fill measures RESOLVED checks, so a red run still completes" do
    progress = Ci::CheckProgress.new(passed: 8, failed: 2, pending: 0)
    render partial: "components/ci_progress_meter",
           locals: { progress: progress, label: "PR: 1", test_id: "task-ci-progress" }

    fill = css_select("[data-test='task-ci-progress-fill']").first
    assert_includes fill["style"], "width: 100%", "every check settled — the bar is full"
    assert_includes fill["class"], "bg-red-500", "and RED is what says the run went bad"
    assert_select "[data-test='task-ci-progress'][data-ci-state='red']", 1
  end

  test "[component] a blank progress renders nothing" do
    render partial: "components/ci_progress_meter",
           locals: { progress: Ci::CheckProgress.blank, label: "PR: 1", test_id: "task-ci-progress" }

    assert_select "[data-test='task-ci-progress']", 0
  end

  private

  def running_progress
    Ci::CheckProgress.from_check_runs([
      { "status" => "completed", "conclusion" => "success", "name" => "lint",
        "started_at" => RUN_START, "completed_at" => RUN_START + 30 },
      { "status" => "in_progress", "name" => "test", "started_at" => RUN_START + 5 }
    ], run_started_at: RUN_START)
  end

  def settled_progress(seconds:)
    Ci::CheckProgress.from_check_runs([
      { "status" => "completed", "conclusion" => "success", "name" => "lint",
        "started_at" => RUN_START, "completed_at" => RUN_START + 30 },
      { "status" => "completed", "conclusion" => "success", "name" => "test",
        "started_at" => RUN_START + 5, "completed_at" => RUN_START + seconds }
    ], run_started_at: RUN_START)
  end
end
