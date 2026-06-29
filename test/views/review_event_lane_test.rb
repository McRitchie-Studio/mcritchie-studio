require "test_helper"

class ReviewEventLaneTest < ActionView::TestCase
  include ReviewEventsHelper

  setup do
    @carl = Agent.create!(name: "Carl", slug: "carl")
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
    @task = Task.create!(title: "review lane view task", stage: "submitted")
    @task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )
    @event = @task.record_review_check_in(
      role: "primary",
      moment: "diff",
      actor: "carl",
      message: "Diff scan reached controllers."
    )
  end

  test "[component] review lane renders swimlane stats and event metadata" do
    lane = review_event_lanes(@task, [@carl, @shannon], [@event]).first

    render partial: "tasks/review_event_lane", locals: { lane: lane }

    assert_select "[data-test='review-event-lane'][data-role='primary']"
    assert_includes rendered, "Heavy Swimlane"
    assert_select "[data-test='review-role-stat'][data-agent='carl']"
    assert_select "[data-test='review-moment'][data-moment='diff'][data-complete='true']"
    assert_select "[data-test='review-event'][data-moment='diff'][data-status='info']"
    assert_includes rendered, "Carl"
    assert_includes rendered, "Audited code diff"
    assert_includes rendered, "Diff scan reached controllers."
  end
end
