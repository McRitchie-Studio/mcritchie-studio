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
    # Activity clears an agent_slug that names no Agent row (ClearsUnknownSlug), so
    # both souls this case stamps need one; the fixtures hold only xan and mack.
    %w[jasper carl].each { |soul| Agent.create!(name: soul.capitalize, slug: soul, status: "active", agent_type: "worker") }

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

  # ---- the review claim's login --------------------------------------------------

  def review_task(title, builder: "pokemon")
    task = Task.create!(title: title, stage: "submitted")
    task.update_column(:metadata, { "devops" => { "built_by" => builder, "builders" => [builder] } })
    task
  end

  # Claims the review over the API and returns the response's session block.
  def claim_review(task, headers: @legacy, reviewer: "carl")
    post review_claim_api_v1_task_path(task.slug), params: { session: "rev-1", nonce: "n", reviewer: reviewer },
                                                   headers: headers, as: :json
    assert_response :ok
    body.dig("data", "agent_session")
  end

  def token_bearer(token) = { "Authorization" => "Bearer #{token}" }

  def move(task, stage, headers)
    patch api_v1_task_path(task.slug), params: { stage: stage }, headers: headers, as: :json
  end

  def post_review_event(task, headers)
    post "/api/v1/tasks/#{task.slug}/review_events",
         params: { review_event: { role: "primary", moment: "diff", actor: "pokemon", message: "read" } },
         headers: headers, as: :json
  end

  test "reviewer session writes review events" do
    task = review_task("Reviewer Writes Events")
    login = claim_review(task)
    assert_equal %w[carl studio review_claim], login.values_at("soul", "tier", "issued_by")

    post_review_event(task, token_bearer(login["token"]))
    assert_response :created
    assert_equal "carl", task.task_events.checkpoints.last.actor

    # Control: the shared token keeps the param.
    other = review_task("Legacy Writes Events")
    post_review_event(other, @legacy)
    assert_response :created
    assert_equal "pokemon", other.task_events.checkpoints.last.actor
  end

  test "claim_next_review returns the reviewer's login with the claimed task" do
    task = review_task("Popped For Review")
    result = Task::ClaimNextResult.new(task: task, reason: "claimed",
                                       outcome: TaskReviewClaim.acquire(task_slug: task.slug, session: "rev-1", nonce: "n",
                                                                        reviewer: "carl", mint_session: true))
    seen = nil
    Task.stub(:claim_next_review, ->(**args) { seen = args; result }) do
      post "/api/v1/tasks/claim_next_review", params: { session: "rev-1", nonce: "n", reviewer: "carl" },
                                              headers: @legacy, as: :json
    end

    assert_response :ok
    assert seen[:mint_session], "the shared token asks for the login"
    assert_equal task.slug, body.dig("data", "claimed", "slug")
    assert_equal result.outcome.agent_session, AgentSession.from_token(body.dig("data", "agent_session", "token"))
  end

  test "a session cannot claim a review login" do
    task = review_task("Builder Claims Review")
    builder = AgentSession.issue_studio!(soul: "pokemon", task: task, issued_by: "task_claim")

    assert_nil claim_review(task, headers: bearer(builder), reviewer: "carl")
    assert body.dig("data", "acquired"), "the lease itself is still taken"
    assert_equal 0, AgentSession.where(issued_by: "review_claim").count
  end

  test "builder session cannot move submitted to reviewed" do
    task = review_task("Builder Moves To Reviewed")
    builder = AgentSession.issue_studio!(soul: "pokemon", task: task, issued_by: "task_claim")

    move(task, "reviewed", bearer(builder))
    assert_response :forbidden
    assert_equal "SESSION_FORBIDDEN", body["error_code"]
    assert_match(/submitted to reviewed is made by a reviewer outside #{task.slug}'s author set/, body["error"])

    patch block_api_v1_task_path(task.slug), params: { kind: "rework" }, headers: bearer(builder), as: :json
    assert_response :forbidden
    assert_match(/submitted to blocked/, body["error"])
    assert_equal "submitted", task.reload.stage
    refute task.blocked?

    # Control: a reviewer outside the author set makes the same move.
    move(task, "reviewed", token_bearer(claim_review(task)["token"]))
    assert_response :ok
    assert_equal "reviewed", task.reload.stage
  end

  test "an outside reviewer blocks a submitted task, and the shared token still moves one" do
    task = review_task("Reviewer Blocks Submitted Task")
    patch block_api_v1_task_path(task.slug), params: { kind: "rework", by: "pokemon" },
                                             headers: token_bearer(claim_review(task)["token"]), as: :json
    assert_response :ok
    assert_equal %w[building carl], [task.reload.stage, task.blocked_by]

    legacy = review_task("Legacy Moves To Reviewed")
    move(legacy, "reviewed", @legacy)
    assert_response :ok
    assert_equal "reviewed", legacy.reload.stage
  end

  test "released claim answers 401" do
    task = review_task("Released Claim Answers Refusal")
    token = claim_review(task)["token"]
    post review_claim_release_api_v1_task_path(task.slug), params: { session: "rev-1", nonce: "n" },
                                                           headers: @legacy, as: :json
    assert_response :ok

    move(task, "reviewed", token_bearer(token))
    assert_response :unauthorized
    assert_equal "SESSION_ENDED", body["error_code"]
    assert_equal "submitted", task.reload.stage
  end

  test "a lapsed claim answers 401, and the verdict ends the session" do
    task = review_task("Lapsed Claim Answers Refusal")
    token = claim_review(task)["token"]

    travel ClaimLease::REVIEW_TTL_SECONDS + 1 do
      move(task, "reviewed", token_bearer(token))
      assert_response :unauthorized
      assert_equal "SESSION_ENDED", body["error_code"]
    end

    move(task, "reviewed", token_bearer(token))
    assert_response :ok
    post_review_event(task, token_bearer(token))
    assert_response :unauthorized
    assert_match(/left review \(it is reviewed\)/, body["error"])
  end

  test "archive needs admin" do
    move(@task, "archived", bearer(@studio))
    assert_response :forbidden
    assert_equal "SESSION_FORBIDDEN", body["error_code"]
    assert_match(/building to archived is an admin transition; jasper holds a studio session/, body["error"])
    assert_equal "building", @task.reload.stage

    move(@task, "archived", bearer(@admin))
    assert_response :ok
    assert_equal "archived", @task.reload.stage

    # Control: the shared token archives.
    other = review_task("Legacy Token Archives Task")
    move(other, "archived", @legacy)
    assert_response :ok
    assert_equal "archived", other.reload.stage
  end
end
