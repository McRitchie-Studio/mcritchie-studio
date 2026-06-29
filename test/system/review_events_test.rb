require "application_system_test_case"

class ReviewEventsTest < ApplicationSystemTestCase
  test "[e2e] reviewer can open event reader from task timeline" do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
    task = Task.create!(title: "review reader system task", stage: "submitted")
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )
    task.record_review_check_in(
      role: "primary",
      moment: "diff",
      actor: "carl",
      message: "System test sees the primary diff checkpoint."
    )
    task.record_review_check_in(
      role: "light",
      moment: "smoke",
      actor: "shannon",
      message: "System test sees the light smoke checkpoint."
    )

    visit task_path(task.slug)
    click_link "Review Events"

    assert_current_path review_events_task_path(task.slug)
    assert_text "PRIMARY REVIEW"
    assert_text "LIGHT REVIEW"
    assert_text "System test sees the primary diff checkpoint."
    assert_text "System test sees the light smoke checkpoint."
  end
end
