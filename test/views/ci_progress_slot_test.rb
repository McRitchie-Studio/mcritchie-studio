require "test_helper"

# [component] The stable-id CI bar slot (components/_ci_progress_slot) — the
# morph-replace target that lets a live workflow_job push swap JUST the bar. The
# invariant this pins: the #dom_id wrapper ALWAYS renders (so the target exists
# before a run's first check settles), and the bar appears inside it only when the
# progress is present.
class CiProgressSlotTest < ActionView::TestCase
  test "[component] the #dom_id wrapper always renders, with the bar inside when present" do
    render partial: "components/ci_progress_slot",
           locals: { dom_id: "ci-progress-my-task",
                     progress: Ci::CheckProgress.new(passed: 3, failed: 0, pending: 5),
                     compact: true, test_id: "task-ci-progress",
                     wrapper_class: "mb-1.5", inner_test_id: "task-card-ci-progress" }

    assert_select "#ci-progress-my-task", 1, "the stable morph target must be present"
    assert_select "#ci-progress-my-task [data-test='task-card-ci-progress']", 1
    assert_select "#ci-progress-my-task [data-test='task-ci-progress'][data-ci-state='pending']", 1
    assert_select "#ci-progress-my-task [data-test='task-ci-progress-fraction']", text: /3 \/ 8/
    assert_select "#ci-progress-my-task .mb-1\\.5", 1, "the wrapper_class rides the inner element"
  end

  test "[component] blank progress still renders the slot wrapper but no bar" do
    render partial: "components/ci_progress_slot",
           locals: { dom_id: "ci-progress-empty", progress: Ci::CheckProgress.blank }

    assert_select "#ci-progress-empty", 1, "the target must exist even before any check lands"
    assert_select "#ci-progress-empty [data-test='ci-progress-bar']", 0, "no bar until there is CI data"
  end

  test "[component] a nil progress renders the wrapper without raising" do
    render partial: "components/ci_progress_slot", locals: { dom_id: "ci-progress-nil", progress: nil }
    assert_select "#ci-progress-nil", 1
    assert_select "#ci-progress-nil [data-test='ci-progress-bar']", 0
  end

  test "[component] a custom label rides through to the bar (the release G3 slot)" do
    render partial: "components/ci_progress_slot",
           locals: { dom_id: "release-ci-progress",
                     progress: Ci::CheckProgress.new(passed: 8, failed: 0, pending: 0),
                     label: "G3 CI", test_id: "release-ci-progress", wrapper_class: "mt-2" }

    assert_select "#release-ci-progress [data-test='release-ci-progress']", 1
    assert_select "#release-ci-progress span", text: "G3 CI"
  end
end
