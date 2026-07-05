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
    click_link "Review Activity"

    assert_current_path review_events_task_path(task.slug)
    assert_text "HEAVY SWIMLANE"
    assert_text "LIGHT SWIMLANE"
    assert_text "System test sees the primary diff checkpoint."
    assert_text "System test sees the light smoke checkpoint."
  end

  test "[e2e] operator opens review process hub from submitted column docs link" do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
    task = Task.create!(title: "review hub system task", stage: "submitted")
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )

    visit deployments_path
    find("[data-test='submitted-review-docs-link']").click

    assert_current_path review_events_hub_path
    assert_text "Review Process Hub"
    assert_text "HEAVY SWIMLANE"
    assert_text "LIGHT SWIMLANE"
    assert_text "review hub system task"
    assert_text "Carl"
    assert_text "Shannon"
  end
end
