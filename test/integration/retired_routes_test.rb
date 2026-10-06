require "test_helper"

# [integration] The legacy aliases are gone: each path answers 404, and the live
# route each one shadowed still answers. The pairs are listed together so a
# reader sees what replaced every retired path.
class RetiredRoutesTest < ActionDispatch::IntegrationTest
  RETIRED_GETS = {
    "/pokemon"                          => "/pokedex",
    "/activities"                       => "/agents",
    "/alex/heartbeat"                   => "/xan/heartbeat",
    "/alex/heartbeat/activities"        => "/xan/heartbeat/activities",
    "/alex/insights"                    => "/xan/insights",
    "/alex/pipeline"                    => "/xan/pipeline",
    "/xan/heartbeat/spans"              => "/xan/heartbeat/activities"
  }.freeze

  RETIRED_POSTS = %w[
    /api/v1/atomic_actions
    /api/v1/atomic_events
    /api/v1/atomic_events/close
    /api/v1/atomic_events/close_all
    /api/v1/atomic_events/1/grade
    /xan/heartbeat/events/1/grade
  ].freeze

  RETIRED_API_GETS = %w[
    /api/v1/atomic_events/awaiting_grade
    /xan/heartbeat/events/1/feedback
  ].freeze

  test "[integration] every retired GET path answers 404" do
    (RETIRED_GETS.keys + RETIRED_API_GETS).each do |path|
      get path
      assert_response :not_found, "#{path} is retired and must not route"
    end
  end

  test "[integration] every retired POST path answers 404" do
    RETIRED_POSTS.each do |path|
      post path, params: {}, as: :json
      assert_response :not_found, "#{path} is retired and must not route"
    end
  end

  # Signed in as the admin, so the check holds whether or not a page sits behind
  # the admin wall.
  test "[integration] the live page each retired GET shadowed still answers" do
    log_in_as(users(:alex))
    RETIRED_GETS.values.uniq.each do |path|
      get path
      assert_response :success, "#{path} is live and must still render"
    end
  end

  test "[unit] the live API routes the aliases fronted still route" do
    assert_routing({ method: "post", path: "/api/v1/agent_actions" },
                   controller: "api/v1/agent_actions", action: "create")
    assert_routing({ method: "post", path: "/api/v1/agent_activities" },
                   controller: "api/v1/agent_activities", action: "create")
    assert_routing({ method: "post", path: "/api/v1/agent_activities/turn_open" },
                   controller: "api/v1/agent_activities", action: "turn_open")
    assert_routing({ method: "get", path: "/api/v1/agent_activities/awaiting_grade" },
                   controller: "api/v1/activity_grades", action: "awaiting")
    assert_routing({ method: "post", path: "/api/v1/agent_activities/1/grade" },
                   controller: "api/v1/activity_grades", action: "create", id: "1")
  end
end
