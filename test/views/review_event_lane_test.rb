require "test_helper"

class ReviewEventLaneTest < ActionView::TestCase
  include ReviewEventsHelper

  setup do
    @carl = Agent.create!(name: "Carl", slug: "carl")
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
    @task = Task.create!(title: "review lane view task", stage: "submitted")
    @base_time = Time.zone.parse("2026-06-29 12:00")
    intent = @task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )
    intent.update!(occurred_at: @base_time - 30.minutes)
    @started_event = @task.record_review_check_in(
      role: "primary",
      moment: "started",
      actor: "carl",
      message: "Heavy review started."
    )
    @started_event.update!(occurred_at: @base_time - 25.minutes)
    @context_event = @task.record_review_check_in(
      role: "primary",
      moment: "context",
      actor: "carl",
      message: "Task context loaded."
    )
    @context_event.update!(occurred_at: @base_time - 20.minutes)
    @event = @task.record_review_check_in(
      role: "primary",
      moment: "diff",
      actor: "carl",
      message: "Diff scan reached controllers."
    )
    @event.update!(occurred_at: @base_time - 10.minutes)
    @task.reload
  end

  test "[component] review lane renders swimlane stats, step durations, and event metadata" do
    lanes = review_event_lanes(@task, [@carl, @shannon], @task.review_check_in_events)
    lane = lanes.first

    render partial: "tasks/review_event_lane", locals: { lane: lane }

    assert_select "[data-test='review-event-lane'][data-role='primary']"
    assert_includes rendered, "Heavy Swimlane"
    assert_select "[data-test='review-role-stat'][data-agent='carl']"
    assert_select "[data-test='review-moment'][data-moment='diff'][data-complete='true']"
    assert_select "[data-test='review-moment'][data-moment='started'] [data-test='review-moment-duration'][data-duration-seconds='300']", text: "5m"
    assert_select "[data-test='review-moment'][data-moment='diff'] [data-test='review-moment-duration'][data-duration-seconds='600']", text: "10m"
    assert_select "[data-test='review-moment'][data-moment='tests'][data-timing-status='live']"
    assert_select "[data-test='review-event'][data-moment='diff'][data-status='info']"
    assert_includes rendered, "Carl"
    assert_includes rendered, "Audited code diff"
    assert_includes rendered, "Diff scan reached controllers."

    light_timings = review_lane_moment_timings(lanes.last, live_at: @base_time)
    assert_equal "live", light_timings.fetch("started").status
    assert_equal 30.minutes.to_i, light_timings.fetch("started").seconds
  end
end
