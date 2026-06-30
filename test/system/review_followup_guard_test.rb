require "application_system_test_case"

class ReviewFollowupGuardTest < ApplicationSystemTestCase
  test "[e2e] submitted task under review shows follow-up guard" do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
    task = Task.create!(title: "review guard system task", stage: "submitted")
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )

    visit tasks_path

    within "#card-#{task.slug}" do
      assert_text "REVIEW STARTED"
    end

    visit task_path(task.slug)

    assert_text "REVIEW STARTED"
    assert_text "Open follow-up work before adding changes to this branch."
  end
end
