require "test_helper"

class ReviewProcessHubIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
  end

  test "[integration] submitted column links to review process hub" do
    task = Task.create!(title: "hub submitted task", stage: "submitted")
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )

    get deployments_path
    assert_response :success
    assert_select "[data-test='submitted-review-docs-link'][href=?]", review_events_hub_path

    get review_events_hub_path
    assert_response :success
    assert_select "[data-test='review-process-hub']"
    assert_select "[data-test='review-event-lane'][data-role='primary']"
    assert_select "[data-test='review-event-lane'][data-role='light']"
    assert_select "[data-test='review-pipeline-task'][data-slug=?]", task.slug
    assert_match "hub submitted task", response.body
    assert_match "Carl", response.body
    assert_match "Shannon", response.body
  end
end
