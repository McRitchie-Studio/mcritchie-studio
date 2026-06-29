require "test_helper"

class ReviewEventLaneTest < ActionView::TestCase
  include ReviewEventsHelper

  setup do
    @carl = Agent.create!(name: "Carl", slug: "carl")
    @task = Task.create!(title: "review lane view task", stage: "submitted")
    @event = @task.record_review_check_in(
      role: "primary",
      moment: "diff",
      actor: "carl",
      message: "Diff scan reached controllers."
    )
  end

  test "[component] review lane renders moment strip and event metadata" do
    lane = review_event_lanes(@task, [@carl], [@event]).first

    render partial: "tasks/review_event_lane", locals: { lane: lane }

    assert_select "[data-test='review-event-lane'][data-role='primary']"
    assert_select "[data-test='review-moment'][data-moment='diff'][data-complete='true']"
    assert_select "[data-test='review-event'][data-moment='diff'][data-status='info']"
    assert_includes rendered, "Carl"
    assert_includes rendered, "Audited code diff"
    assert_includes rendered, "Diff scan reached controllers."
  end
end
