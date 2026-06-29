require "application_system_test_case"

class TaskConversationTaxonomyTest < ApplicationSystemTestCase
  test "[e2e] task board shows clarification without blocking" do
    task = Task.create!(title: "clarification board signal", stage: "submitted")
    Activity.create!(
      task_slug: task.slug,
      activity_type: "clarification",
      description: "Can you confirm whether this needs a PR comment too?"
    )

    visit tasks_path

    assert_selector "#card-#{task.slug}[data-stage='submitted']"
    assert_selector "#card-#{task.slug} [data-test='activity-box'][data-activity-type='clarification']",
                    text: "Can you confirm whether this needs a PR comment too?"
    assert_selector "#card-#{task.slug} [data-test='activity-type-label']", text: "CLARIFICATION"
    assert_no_selector "#card-#{task.slug}[data-stage='blocked']"
  end
end
