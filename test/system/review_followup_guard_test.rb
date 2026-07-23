require "application_system_test_case"

class ReviewFollowupGuardTest < ApplicationSystemTestCase
  test "[e2e] submitted task under review shows the follow-up guard on the task page" do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
    task = Task.create!(title: "review guard system task", stage: "submitted")
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )

    # The REVIEW STARTED card flag was dropped (the deploy-board crew avatar carries
    # live review now); the follow-up guard is the task page's own review label.
    visit task_path(task.slug)

    assert_text "REVIEW STARTED"
    assert_text "Open follow-up work before adding changes to this branch."
  end
end
