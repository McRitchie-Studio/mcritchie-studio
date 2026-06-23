require "test_helper"

class TaskTimelineTest < ActionDispatch::IntegrationTest
  # [component] the timeline section renders on the public task show page,
  # with a badge per transition.
  test "task show page renders the stage timeline with event badges" do
    task = Task.create!(title: "Timeline render task", stage: "designed")
    task.update!(stage: "building")

    get task_path(task.slug)

    assert_response :success
    assert_select "[data-test='stage-timeline']"
    assert_match "Stage Timeline", response.body
    # genesis (Created → Designed) and the designed → building transition both show
    assert_match "Created", response.body
    assert_match "Designed", response.body
    assert_match "Building", response.body
  end

  # [integration] an API stage move carrying a usage payload records a fully
  # annotated TaskEvent end-to-end, and the model surfaces on the timeline.
  test "api stage move with usage records a TaskEvent and shows it on the timeline" do
    task = Task.create!(title: "Timeline api task", stage: "designed")
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

    assert_difference -> { task.task_events.count }, 1 do
      patch "/api/v1/tasks/#{task.slug}",
            params: { stage: "building",
                      event: { model: "claude-opus-4-8", tokens_in: 1000, tokens_out: 2000, cost: "0.30" } },
            headers: { "Authorization" => "Bearer #{token}" },
            as: :json
    end
    assert_response :success

    event = task.task_events.chronological.last
    assert_equal "building", event.to_stage
    assert_equal "claude-opus-4-8", event.model
    assert_equal 3000, event.tokens_total
    assert_equal "0.30".to_d, event.cost
    assert_equal "api", event.source

    get task_path(task.slug)
    assert_response :success
    assert_match "claude-opus-4-8", response.body
  end
end
