require "test_helper"

# [component] The reusable CI progress bar (components/_ci_progress_bar) — renders
# a Ci::CheckProgress as "X / Y checks" plus a state-coloured filled bar, and
# renders nothing at all when there is no CI data. Pinned in isolation.
class CiProgressBarTest < ActionView::TestCase
  test "[component] renders the fraction, pending state, and a partial bar" do
    render partial: "components/ci_progress_bar",
           locals: { progress: Ci::CheckProgress.new(passed: 3, failed: 0, pending: 5) }

    assert_select "[data-test='ci-progress-bar'][data-ci-state='pending']", 1
    assert_select "[data-test='ci-progress-bar-fraction']", text: /3 \/ 8/
    assert_select "[role='progressbar'][aria-valuenow='3'][aria-valuemax='8']", 1
    # 3/8 = 37.5 -> rounds to 38%.
    assert_select "[data-test='ci-progress-bar-fill'][style*='width: 38%']", 1
  end

  test "[component] a green run fills the bar and wears the pass colour" do
    all_pass = Array.new(8) { { "status" => "completed", "conclusion" => "success" } }
    render partial: "components/ci_progress_bar",
           locals: { progress: Ci::CheckProgress.from_check_runs(all_pass) }

    assert_select "[data-ci-state='green']", 1
    fill = css_select("[data-test='ci-progress-bar-fill']").first
    assert_includes fill["class"], "bg-emerald-500"
    assert_includes fill["style"], "width: 100%"
  end

  test "[component] a failing run wears the red colour" do
    render partial: "components/ci_progress_bar",
           locals: { progress: Ci::CheckProgress.new(passed: 5, failed: 1, pending: 2) }

    assert_select "[data-ci-state='red']", 1
    assert_includes css_select("[data-test='ci-progress-bar-fill']").first["class"], "bg-red-500"
  end

  test "[component] a custom label and test_id are honoured" do
    render partial: "components/ci_progress_bar",
           locals: { progress: Ci::CheckProgress.new(passed: 1, failed: 0, pending: 7),
                     label: "G3 CI", test_id: "release-ci-progress" }

    assert_select "[data-test='release-ci-progress']", 1
    assert_select "[data-test='release-ci-progress-fraction']", 1
    assert_select "span", text: "G3 CI"
  end

  test "[component] blank progress renders nothing" do
    render partial: "components/ci_progress_bar", locals: { progress: Ci::CheckProgress.blank }
    assert_select "[data-test='ci-progress-bar']", 0
  end

  test "[component] a nil progress renders nothing" do
    render partial: "components/ci_progress_bar", locals: { progress: nil }
    assert_select "[data-test='ci-progress-bar']", 0
  end
end
