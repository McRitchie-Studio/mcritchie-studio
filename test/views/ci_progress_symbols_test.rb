require "test_helper"

# [component] The symbolic CI row (components/_ci_progress_symbols) — one line ICON
# per check for a small suite: a green check passed, a red x failed, an amber loader
# spinning for running. Pinned in isolation: the icon count maps 1:1 to the checks,
# each carries its real state + colour, the running icon spins, and the row exposes
# one summary label to assistive tech.
class CiProgressSymbolsTest < ActionView::TestCase
  def render_symbols(progress, **locals)
    render partial: "components/ci_progress_symbols", locals: { progress: progress, **locals }
  end

  test "[component] draws one SVG icon per check, 1:1 with the CI jobs" do
    render_symbols Ci::CheckProgress.from_check_runs([
      { "status" => "completed", "conclusion" => "success", "name" => "lint" },
      { "status" => "completed", "conclusion" => "failure", "name" => "test" },
      { "status" => "in_progress", "name" => "playwright (1)" }
    ])

    assert_select "[data-test='ci-progress-bar-symbols'][data-ci-state='red']", 1
    assert_select "[data-test='ci-check-symbol']", 3
    assert_select "[data-test='ci-check-symbol'] svg", 3, "each check draws a clean SVG icon, not an emoji"
    assert_select "[data-test='ci-check-symbol'][data-ci-check-state='passed']", 1
    assert_select "[data-test='ci-check-symbol'][data-ci-check-state='failed']", 1
    assert_select "[data-test='ci-check-symbol'][data-ci-check-state='pending']", 1
  end

  test "[component] each state wears its colour; the running loader spins" do
    render_symbols Ci::CheckProgress.new(passed: 1, failed: 1, pending: 1)

    passed = css_select("[data-ci-check-state='passed']").first
    assert_includes passed["class"], "text-emerald-600", "passed is a green check"
    assert_select "[data-ci-check-state='passed'] svg", 1

    failed = css_select("[data-ci-check-state='failed']").first
    assert_includes failed["class"], "text-red-600", "failed is a red x"
    assert_select "[data-ci-check-state='failed'] svg", 1

    running = css_select("[data-ci-check-state='pending']").first
    assert_includes running["class"], "text-amber-600", "running is an amber loader"
    assert_includes running["class"], "animate-spin", "the running/queued loader spins"
    assert_select "[data-ci-check-state='pending'] svg", 1
    assert_select "[data-ci-check-state='pending'] svg circle", 1, "the loader is a ring, not an emoji"
  end

  test "[component] the row exposes one summary label to assistive tech" do
    render_symbols Ci::CheckProgress.new(passed: 6, failed: 0, pending: 2)

    row = css_select("[data-test='ci-progress-bar-symbols']").first
    assert_equal "img", row["role"]
    assert_equal "6 of 8 CI checks passed", row["aria-label"]
  end

  test "[component] a job name rides along as the glyph's hover title" do
    render_symbols Ci::CheckProgress.from_check_runs([
      { "status" => "completed", "conclusion" => "success", "name" => "lint" }
    ])

    assert_select "[data-test='ci-check-symbol'][title='lint — passed']", 1
  end

  test "[component] a custom label rides through (the release G3 row)" do
    render_symbols Ci::CheckProgress.new(passed: 8, failed: 0, pending: 0), label: "G3 CI", test_id: "release-ci-progress"

    assert_select "[data-test='release-ci-progress-symbols']", 1
    assert_select "span", text: "G3 CI"
  end

  test "[component] blank progress renders nothing" do
    render_symbols Ci::CheckProgress.blank
    assert_select "[data-test='ci-progress-bar-symbols']", 0
  end
end
