require "test_helper"

# [integration] The session gate reaches every board write, not only the task and
# release sinks:
#
# - the conductor lanes (devops shifts) and an agent update are admin-tier writes:
#   a studio session answers 403 with the reason, an admin session passes;
# - desk_records, activities, agent_activities and agent_actions record the actor
#   from the session when one is present, and ignore the param.
#
# Each case carries its control: the shared secret's token keeps working and keeps
# the param, for the one release it stays accepted.
class AgentSessionBoardWritesTest < ActionDispatch::IntegrationTest
  setup do
    @task = tasks(:in_progress_task) # building
    @legacy = { "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}" }
    @studio = AgentSession.issue_studio!(soul: "jasper", task: @task, issued_by: "task_claim")
    @admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
  end

  def bearer(session) = { "Authorization" => "Bearer #{session.token}" }

  def body = JSON.parse(response.body)

  # ---- admin-tier writes ------------------------------------------------------

  def acquire(headers, session: "conductor-1", lane: "avi")
    post acquire_api_v1_devops_shifts_path, params: { lane: lane, session: session, nonce: "n" },
                                            headers: headers, as: :json
  end

  test "a studio session cannot acquire, renew or release a conductor lane" do
    acquire(bearer(@studio))
    assert_response :forbidden
    assert_equal "SESSION_FORBIDDEN", body["error_code"]
    assert_match(/needs an admin session; jasper holds a studio session/, body["error"])
    assert_equal 0, DevopsShift.where.not(claimed_session: nil).count

    acquire(@legacy) # someone holds it, so renew and release have a target
    %i[renew release].each do |action|
      post "/api/v1/devops_shifts/#{action}", params: { lane: "avi", session: "conductor-1", nonce: "n" },
                                              headers: bearer(@studio), as: :json
      assert_response :forbidden, action
    end
    assert DevopsShift.find_by(lane: "avi").claimed_session.present?, "the studio release did not drop the lane"
  end

  test "an admin session and the shared token acquire a conductor lane" do
    acquire(bearer(@admin), lane: "steffon")
    assert_response :ok
    assert body.dig("data", "acquired")

    acquire(@legacy, lane: "xan")
    assert_response :ok
    assert body.dig("data", "acquired")
  end

  test "a studio session reads the lanes" do
    get api_v1_devops_shifts_path, headers: bearer(@studio)

    assert_response :ok
  end

  test "a studio session cannot update an agent; an admin session and the shared token can" do
    agent = agents(:xan_agent)

    patch api_v1_agent_path(agent.slug), params: { config: { "model" => "forged" } },
                                         headers: bearer(@studio), as: :json
    assert_response :forbidden
    assert_match(/needs an admin session; jasper holds a studio session/, body["error"])
    assert_nil agent.reload.config.to_h["model"]

    patch api_v1_agent_path(agent.slug), params: { config: { "model" => "by-admin" } },
                                         headers: bearer(@admin), as: :json
    assert_response :ok
    assert_equal "by-admin", agent.reload.config["model"]

    patch api_v1_agent_path(agent.slug), params: { config: { "model" => "by-legacy" } },
                                         headers: @legacy, as: :json
    assert_response :ok
    assert_equal "by-legacy", agent.reload.config["model"]
  end

  test "a studio session still reads an agent" do
    get api_v1_agent_path(agents(:xan_agent).slug), headers: bearer(@studio)

    assert_response :ok
  end

  # ---- the actor comes from the session ----------------------------------------

  def file_desk(headers, path)
    post api_v1_desk_records_path, params: { desk: { worktree_path: path, status: "live", actor: "carl" } },
                                   headers: headers, as: :json
  end

  test "a desk record stamps the session soul, and the shared token keeps the param" do
    file_desk(bearer(@studio), "/tmp/desks/session")
    assert_response :created
    assert_equal "jasper", DeskRecord.find_by!(worktree_path: "/tmp/desks/session").actor

    file_desk(@legacy, "/tmp/desks/legacy")
    assert_response :created
    assert_equal "carl", DeskRecord.find_by!(worktree_path: "/tmp/desks/legacy").actor
  end

  def post_activity(headers, description)
    post api_v1_activities_path, params: { agent_slug: "carl", activity_type: "comment", description: description,
                                           task_slug: @task.slug }, headers: headers, as: :json
  end

  test "an activity stamps the session soul, and the shared token keeps the param" do
    post_activity(bearer(@studio), "from the session")
    assert_response :created
    assert_equal "jasper", Activity.find_by!(description: "from the session").agent_slug

    post_activity(@legacy, "from the shared token")
    assert_response :created
    assert_equal "carl", Activity.find_by!(description: "from the shared token").agent_slug
  end

  def open_activity(headers, session_id)
    post api_v1_agent_activities_path, params: { session_id: session_id, category: "Explore", reason: "look",
                                                 agent: "carl" }, headers: headers, as: :json
  end

  test "an agent activity opens and closes in the session soul's lane, and the shared token keeps the param" do
    open_activity(bearer(@studio), "harness-s")
    assert_response :created
    opened = AgentActivity.find_by!(session_id: "harness-s")
    assert_equal "jasper", opened.agent

    # A close naming another lane still closes the session soul's own lane.
    post close_api_v1_agent_activities_path, params: { session_id: "harness-s", agent: "carl", outcome: "done" },
                                             headers: bearer(@studio), as: :json
    assert_response :ok
    assert opened.reload.closed_at.present?

    open_activity(@legacy, "harness-l")
    assert_response :created
    assert_equal "carl", AgentActivity.find_by!(session_id: "harness-l").agent
  end

  def post_action(headers, session_id)
    post api_v1_agent_actions_path, params: { session_id: session_id, kind: "bash", actor: "human" },
                                    headers: headers, as: :json
  end

  # agent_actions.actor is a lane (harness, agent, board, human), not a soul: a
  # session is an agent, so it records `agent` and cannot claim the operator's lane.
  test "an agent action under a session records the agent lane, and the shared token keeps the param" do
    post_action(bearer(@studio), "harness-a")
    assert_response :created
    assert_equal "agent", AgentAction.find_by!(session_id: "harness-a").actor

    post_action(@legacy, "harness-b")
    assert_response :created
    assert_equal "human", AgentAction.find_by!(session_id: "harness-b").actor
  end
end
