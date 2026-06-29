require "test_helper"

class ReviewProcessHubTest < ActiveSupport::TestCase
  setup do
    @carl = Agent.create!(name: "Carl", slug: "carl")
    @jasper = Agent.create!(name: "Jasper", slug: "jasper")
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
  end

  test "[unit] aggregates reviewer role stats by distinct task" do
    first = Task.create!(title: "hub first task", stage: "submitted")
    first.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )
    first.record_review_check_in(role: "primary", moment: "diff", actor: "carl")
    first.record_review_check_in(role: "primary", moment: "tests", actor: "carl")

    second = Task.create!(title: "hub second task", stage: "submitted")
    second.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "heavy" }, { "slug" => "shannon", "weight" => "light" }]
    )

    third = Task.create!(title: "hub third task", stage: "submitted")
    third.record_review_check_in(role: "primary", moment: "diff", actor: "jasper")

    hub = ReviewProcessHub.new(agents: [@carl, @jasper, @shannon])

    heavy = hub.top_agents("heavy")
    assert_equal "carl", heavy.first.slug
    assert_equal 2, heavy.first.count
    assert_equal ["carl", "jasper"], heavy.map(&:slug)

    light = hub.top_agents("light")
    assert_equal "shannon", light.first.slug
    assert_equal 2, light.first.count

    snapshot = hub.snapshot_for(first)
    assert_equal "carl", snapshot.reviewer_for("primary").slug
    assert_equal "shannon", snapshot.reviewer_for("light").slug
    assert_equal 2, snapshot.review_event_count
  end
end
