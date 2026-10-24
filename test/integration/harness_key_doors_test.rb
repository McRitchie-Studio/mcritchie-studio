require "test_helper"

# [integration] The doors a harness key opens beyond the mint doors
# (docs/agents/system/agent-sessions-design.md, section 9, questions 4 and 5): the
# board's reads, narration, a task's create and its claim. On each the key is
# accepted, is never counted as a legacy use, and a revoked or unknown key is
# refused with the way to get one. The key still writes no task but its claim.
class HarnessKeyDoorsTest < ActionDispatch::IntegrationTest
  setup do
    @legacy = { "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}" }
    @building = tasks(:in_progress_task)
    @designed = tasks(:queued_task)
    @key = AgentSession.grant_harness_key!(label: "studio-mac", issued_by: "operator_grant")
  end

  def bearer(session) = { "Authorization" => "Bearer #{session.token}" }
  def body = JSON.parse(response.body)

  # One call per door this piece opened, each as a lambda over the headers.
  def door_calls
    sid = "sess-doors-#{SecureRandom.hex(3)}"
    {
      "GET api/v1/tasks#index" => ->(h) { get api_v1_tasks_path, headers: h },
      "GET api/v1/tasks#show" => ->(h) { get api_v1_task_path(@building.slug), headers: h },
      "GET api/v1/tasks#building_lane" => ->(h) { get "/api/v1/tasks/#{@designed.slug}/building_lane", headers: h },
      "GET api/v1/task_review_claims#show" => ->(h) { get "/api/v1/tasks/#{@building.slug}/review_claim", headers: h },
      "GET api/v1/activities#index" => ->(h) { get "/api/v1/activities", headers: h },
      "GET api/v1/gate_runs#index" => ->(h) { get "/api/v1/gates/task/#{@building.slug}", headers: h },
      "GET api/v1/release_conductor_claims#live" => ->(h) { get "/api/v1/release_conductor_claims/live", headers: h },
      "GET api/v1/release_conductor_claims#show" => ->(h) { get "/api/v1/releases/no-such-release/conductor_claim", headers: h },
      "GET api/v1/review_pending_actions#index" => ->(h) { get "/api/v1/review_pending_actions", headers: h },
      "GET api/v1/devops_shifts#index" => ->(h) { get "/api/v1/devops_shifts", headers: h },
      "GET api/v1/desk_records#index" => ->(h) { get "/api/v1/desk_records", headers: h },
      "GET api/v1/agents#index" => ->(h) { get "/api/v1/agents", headers: h },
      "GET api/v1/agents#show" => ->(h) { get "/api/v1/agents/ray", headers: h },
      "GET api/v1/insights#index" => ->(h) { get "/api/v1/insights", headers: h },
      "GET api/v1/agent_activities#windows" => ->(h) { get "/api/v1/agent_activities/windows?session_id=#{sid}", headers: h },
      "GET api/v1/activity_grades#awaiting" => ->(h) { get "/api/v1/agent_activities/awaiting_grade", headers: h },
      "POST api/v1/agent_activities#create" => ->(h) { post "/api/v1/agent_activities", params: { session_id: sid, category: "Explore", reason: "read the board" }, headers: h, as: :json },
      "POST api/v1/agent_activities#close" => ->(h) { post "/api/v1/agent_activities/close", params: { session_id: sid, outcome: "read it" }, headers: h, as: :json },
      "POST api/v1/agent_activities#close_all" => ->(h) { post "/api/v1/agent_activities/close_all", params: { session_id: sid }, headers: h, as: :json },
      "POST api/v1/agent_activities#turn_open" => ->(h) { post "/api/v1/agent_activities/turn_open", params: { session_id: sid }, headers: h, as: :json },
      "POST api/v1/agent_activities#reconcile" => ->(h) { post "/api/v1/agent_activities/reconcile", params: { session_id: sid, usages: [] }, headers: h, as: :json },
      "POST api/v1/agent_actions#create" => ->(h) { post "/api/v1/agent_actions", params: { session_id: sid, kind: "tool_call" }, headers: h, as: :json },
      "POST api/v1/tasks#create" => ->(h) { post api_v1_tasks_path, params: { title: "Made On A Keyed Machine #{SecureRandom.hex(2)}" }, headers: h, as: :json },
      "PATCH api/v1/tasks#update (claim)" => ->(h) { patch api_v1_task_path(@designed.slug), params: { stage: "building", event: { source: "cli", actor: "pokemon" } }, headers: h, as: :json }
    }
  end

  test "every door this piece opened is one the census names, and no other" do
    expected = door_calls.keys + [ "GET api/v1/agent_sessions#show", "PUT api/v1/tasks#update (claim)" ]
    assert_equal expected.sort, LegacyAuthUse.harness_key_doors
  end

  test "the harness key is accepted on each door it opens" do
    door_calls.each do |door, call|
      call.call(bearer(@key))
      assert_not_includes [ 401, 403 ], response.status, "#{door}: #{response.body}"
      assert response.status < 500, door
    end
    assert_equal "building", @designed.reload.stage, "the key made the claim"
  end

  test "a harness-key call on each opened door records no legacy use" do
    assert_no_difference -> { LegacyAuthUse.sum(:uses) } do
      door_calls.each_value { |call| call.call(bearer(@key)) }
    end
  end

  test "a revoked harness key is refused on each door with the way to get one" do
    @key.revoke!(by: "alex@mcritchie.studio")
    door_calls.each do |door, call|
      call.call(bearer(@key))
      assert_response :unauthorized, door
      assert_equal "SESSION_ENDED", body["error_code"], door
      assert_match(/was revoked by alex@mcritchie.studio; a machine with no live harness key asks for one with `bin\/harness-key request`/, body["error"], door)
    end
    assert_equal "designed", @designed.reload.stage
  end

  test "an unknown key is refused on each door with the way to get one" do
    unknown = AgentSession.verifier.generate({ "sid" => "sess-not-on-the-board" }, purpose: AgentSession::TOKEN_PURPOSE, expires_in: 1.hour)
    door_calls.each do |door, call|
      call.call({ "Authorization" => "Bearer #{unknown}" })
      assert_response :unauthorized, door
      assert_match(/Invalid or expired token; a machine with no live harness key asks for one with `bin\/harness-key request`/, body["error"], door)
    end

    # Control: a door the key does not open names no key.
    post "/api/v1/activities", params: { activity: { activity_type: "note" } }, headers: { "Authorization" => "Bearer #{unknown}" }, as: :json
    assert_response :unauthorized
    assert_equal "Invalid or expired token", body["error"]
  end

  test "the shared token still passes every door, and the census counts it, the claim apart" do
    door_calls.each do |door, call|
      call.call(@legacy.merge("X-Agent-Caller" => "bin/task"))
      assert_not_includes [ 401, 403 ], response.status, door
    end

    assert_equal door_calls.size, LegacyAuthUse.where(endpoint: door_calls.keys, caller: "bin/task").sum(:uses)
    assert_equal 1, LegacyAuthUse.where(endpoint: "PATCH api/v1/tasks#update (claim)").sum(:uses)
    assert_equal door_calls.size, LegacyAuthUse.on_harness_key_doors
  end

  test "a task update that is not the claim is counted under the action alone" do
    patch api_v1_task_path(@building.slug), params: { title: "Renamed Under The Shared Token" }, headers: @legacy, as: :json
    assert_response :ok

    assert_equal 1, LegacyAuthUse.where(endpoint: "PATCH api/v1/tasks#update").sum(:uses)
    assert_equal 0, LegacyAuthUse.on_harness_key_doors
  end

  # ---- what the key still may not write ----------------------------------------

  test "a task write other than the claim is refused under the key alone" do
    @building.update_column(:metadata, @building.metadata.to_h.merge("devops" => { "built_by" => "pokemon", "builders" => [ "pokemon" ] }))
    writes = {
      "a stage move to submitted" => [ @building, { stage: "submitted" }, /this update is not the claim/ ],
      "a move to archived" => [ @designed, { stage: "archived" }, /this update is not the claim/ ],
      "checks" => [ @building, { devops: { checks: { "unit" => "pass" } } }, /this update is not the claim/ ],
      "a title" => [ @building, { title: "Renamed By A Key" }, /this update is not the claim/ ],
      "a claim that writes more than the claim" => [ @designed, { stage: "building", title: "Renamed In The Claim" }, /carries only stage, event, devops, dev_size, not title/ ],
      "a claim that writes more in the query string" => [ @designed, { stage: "building" }, /carries only stage, event, devops, dev_size, not agent_slug, title/, "?title=Smuggled&agent_slug=ray" ],
      "a claim of a submitted task" => [ Task.create!(title: "Submitted Elsewhere", stage: "submitted"), { stage: "building" }, /claims a designed or building task; .* is submitted/ ]
    }
    writes.each do |name, (task, params, reason, query)|
      before = task.reload.attributes.slice("stage", "title", "metadata")
      patch "#{api_v1_task_path(task.slug)}#{query}", params: params, headers: bearer(@key), as: :json
      assert_response :forbidden, name
      assert_equal "SESSION_FORBIDDEN", body["error_code"], name
      assert_match reason, body["error"], name
      assert_equal before, task.reload.attributes.slice("stage", "title", "metadata"), name
    end

    assert_no_difference -> { Activity.count } do
      post "/api/v1/activities", params: { task_slug: @building.slug, activity_type: "note", description: "a note" }, headers: bearer(@key), as: :json
    end
    assert_response :forbidden

    assert_no_difference -> { TaskEvent.count } do
      patch "/api/v1/tasks/#{@building.slug}/block", params: { feedback: "no" }, headers: bearer(@key), as: :json
    end
    assert_response :forbidden

    # Control: the shared token still makes the same move.
    patch api_v1_task_path(@building.slug), params: { stage: "submitted" }, headers: @legacy, as: :json
    assert_response :ok
  end

  test "a harness key creates a task only in designed" do
    assert_no_difference -> { Task.count } do
      post api_v1_tasks_path, params: { title: "Born Shipped On A Key", stage: "shipped" }, headers: bearer(@key), as: :json
    end
    assert_response :forbidden
    assert_match(/creates a task in designed, not shipped/, body["error"])

    post api_v1_tasks_path, params: { title: "Born Designed On A Key", stage: "designed" }, headers: bearer(@key), as: :json
    assert_response :created
  end

  # ---- attribution ---------------------------------------------------------------

  test "the claim under a key records the builder it names, and the key then mints that builder's login" do
    patch api_v1_task_path(@designed.slug), params: { stage: "building", event: { source: "cli", actor: "carl", session: "harness-1" } },
                                            headers: bearer(@key), as: :json
    assert_response :ok
    assert_equal "carl", @designed.reload.devops_built_by

    post api_v1_agent_sessions_path, params: { soul: "carl", task_slug: @designed.slug }, headers: bearer(@key), as: :json
    assert_response :created
    login = AgentSession.from_token(body.dig("data", "token"))
    assert_equal [ "carl", "studio", @designed.slug ], [ login.soul, login.tier, login.task_slug ]
  end

  test "narration under the key keeps the lane it declares; under a login the soul is the lane" do
    post "/api/v1/agent_activities", params: { session_id: "sess-lanes", category: "Explore", reason: "logged out", mascot: "pikachu" },
                                     headers: bearer(@key), as: :json
    assert_response :created
    logged_out = AgentActivity.find(body.dig("data", "id"))
    assert_equal [ nil, "pikachu" ], [ logged_out.agent, logged_out.mascot ], "logged out, the activity is the mascot's"

    @building.update_column(:metadata, @building.metadata.to_h.merge("devops" => { "built_by" => "pokemon", "builders" => [ "pokemon", "shannon" ] }))
    login = AgentSession.issue_studio!(soul: "shannon", task: @building, issued_by: "task_claim")
    post "/api/v1/agent_activities", params: { session_id: "sess-lanes-2", category: "Explore", reason: "logged in", agent: "steffon" },
                                     headers: bearer(login), as: :json
    assert_response :created
    assert_equal "shannon", AgentActivity.find(body.dig("data", "id")).agent, "a login names the soul and ignores the param"
  end

  test "an action under the key records the agent lane" do
    post "/api/v1/agent_actions", params: { session_id: "sess-act", kind: "tool_call", actor: "board" }, headers: bearer(@key), as: :json
    assert_response :created
    assert_equal AgentAction::AGENT, AgentAction.find(body.dig("data", "id")).actor
  end
end
