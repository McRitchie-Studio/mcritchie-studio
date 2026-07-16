require "test_helper"

# [component] The stable-id CI meter slot (components/_ci_progress_slot) — the
# morph-replace target that lets a live workflow_job push swap JUST the meter. The
# invariants it pins: the #dom_id wrapper ALWAYS renders (so the target exists
# before a run's first check settles); the meter appears inside only when present;
# FEW checks render the symbolic row while MANY keep the numeric bar; and a `href`
# turns the whole meter into a new-tab PR link.
class CiProgressSlotTest < ActionView::TestCase
  test "[component] a large suite keeps the numeric bar inside the stable target" do
    render partial: "components/ci_progress_slot",
           locals: { dom_id: "ci-progress-my-task",
                     progress: many_checks(passed: 6, pending: 8), # 14 -> numeric
                     compact: true, test_id: "task-ci-progress",
                     wrapper_class: "mb-1.5", inner_test_id: "task-card-ci-progress" }

    assert_select "#ci-progress-my-task", 1, "the stable morph target must be present"
    assert_select "#ci-progress-my-task [data-test='task-card-ci-progress']", 1
    assert_select "#ci-progress-my-task [data-test='task-ci-progress'][data-ci-state='pending']", 1
    assert_select "#ci-progress-my-task [data-test='task-ci-progress-fraction']", text: /6 \/ 14/
    assert_select "#ci-progress-my-task .mb-1\\.5", 1, "the wrapper_class rides the inner element"
  end

  test "[component] a small suite renders one symbol per check, no numeric fraction" do
    render partial: "components/ci_progress_slot",
           locals: { dom_id: "ci-progress-few",
                     progress: Ci::CheckProgress.new(passed: 5, failed: 1, pending: 2), # 8 -> symbolic
                     compact: true, test_id: "task-ci-progress",
                     wrapper_class: "mb-1.5", inner_test_id: "task-card-ci-progress" }

    assert_select "#ci-progress-few [data-test='task-card-ci-progress']", 1
    assert_select "#ci-progress-few [data-test='task-ci-progress-symbols'][data-ci-state='red']", 1
    assert_select "#ci-progress-few [data-test='ci-check-symbol']", 8, "one glyph per check, 1:1 with the jobs"
    assert_select "#ci-progress-few [data-test='ci-check-symbol'][data-ci-check-state='failed']", 1
    assert_select "#ci-progress-few [data-test='task-ci-progress-fraction']", 0, "the fraction gives way to symbols"
  end

  test "[component] a href turns the meter into a new-tab PR link that stops card nav" do
    render partial: "components/ci_progress_slot",
           locals: { dom_id: "ci-progress-linked",
                     progress: Ci::CheckProgress.new(passed: 3, failed: 0, pending: 5),
                     test_id: "task-ci-progress", inner_test_id: "task-card-ci-progress",
                     href: "https://github.com/amcritchie/mcritchie-studio/pull/42" }

    link = "#ci-progress-linked a[data-test='task-card-ci-progress']"
    assert_select "#{link}[href='https://github.com/amcritchie/mcritchie-studio/pull/42']", 1
    assert_select "#{link}[target='_blank'][rel='noopener']", 1
    # @click.stop (card-nav guard) is an Alpine attr Nokogiri's CSS can't target;
    # asserted at the integration/e2e tier where the browser evaluates it.
    assert_includes rendered, "@click.stop", "the link stops the card's open-task click"
  end

  test "[component] no href renders a plain div, not a link" do
    render partial: "components/ci_progress_slot",
           locals: { dom_id: "ci-progress-plain",
                     progress: Ci::CheckProgress.new(passed: 3, failed: 0, pending: 5),
                     inner_test_id: "task-card-ci-progress" }

    assert_select "#ci-progress-plain a", 0, "no PR context -> no link"
    assert_select "#ci-progress-plain div[data-test='task-card-ci-progress']", 1
  end

  test "[component] blank progress still renders the slot wrapper but no meter" do
    render partial: "components/ci_progress_slot",
           locals: { dom_id: "ci-progress-empty", progress: Ci::CheckProgress.blank }

    assert_select "#ci-progress-empty", 1, "the target must exist even before any check lands"
    assert_select "#ci-progress-empty [data-test='ci-progress-bar']", 0, "no bar until there is CI data"
    assert_select "#ci-progress-empty [data-test='ci-progress-bar-symbols']", 0, "no symbols either"
  end

  test "[component] a nil progress renders the wrapper without raising" do
    render partial: "components/ci_progress_slot", locals: { dom_id: "ci-progress-nil", progress: nil }
    assert_select "#ci-progress-nil", 1
    assert_select "#ci-progress-nil [data-test='ci-progress-bar']", 0
  end

  test "[component] a custom label rides through to the meter (the release G3 slot)" do
    render partial: "components/ci_progress_slot",
           locals: { dom_id: "release-ci-progress",
                     progress: Ci::CheckProgress.new(passed: 8, failed: 0, pending: 0), # 8 -> symbolic
                     label: "G3 CI", test_id: "release-ci-progress", wrapper_class: "mt-2" }

    assert_select "#release-ci-progress [data-test='release-ci-progress-symbols']", 1
    assert_select "#release-ci-progress span", text: "G3 CI"
  end

  private

  def many_checks(passed:, pending:)
    runs = Array.new(passed) { { "status" => "completed", "conclusion" => "success" } } +
           Array.new(pending) { { "status" => "in_progress" } }
    Ci::CheckProgress.from_check_runs(runs)
  end
end
