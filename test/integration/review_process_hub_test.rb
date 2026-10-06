require "test_helper"

class ReviewProcessHubIntegrationTest < ActionDispatch::IntegrationTest
  # The ops pages sit behind the admin wall (AdminWall); these tests read them as
  # the operator. A test about another viewer signs that session in itself.
  setup { log_in_as(users(:alex)) }

  setup do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
  end

  test "[integration] deployment link menu links to review process hub" do
    task = Task.create!(title: "hub submitted task", stage: "submitted")
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )

    get deployments_path
    assert_response :success
    assert_select "[data-test='deployment-link-menu-docs'][href=?]", review_events_hub_path

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
