require "test_helper"

# [integration] One machine's harness key: the request, the operator's two grants,
# the single collect, and what the key reaches. It mints studio logins and posts
# login requests; every other endpoint answers it 403. Each refusal carries its
# control.
class HarnessKeyTest < ActionDispatch::IntegrationTest
  HARNESS = "harness-one".freeze

  setup do
    @legacy = { "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}" }
    @task = tasks(:in_progress_task) # building
    @task.update_column(:metadata, @task.metadata.to_h.merge("devops" => { "built_by" => "pokemon", "builders" => [ "pokemon" ] }))
    @studio = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")
    @admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
    @client = AgentSession.create!(soul: "tyrion", tier: "client", issued_by: "runtime_key")
  end

  def bearer(session) = { "Authorization" => "Bearer #{session.token}" }
  def body = JSON.parse(response.body)

  def ask(headers = @legacy, label: "studio-mac", harness: HARNESS)
    post "/api/v1/agent_login_requests", params: { kind: "harness_key", label: label, harness_session_id: harness, soul: "xan" }.compact,
                                         headers: headers, as: :json
  end

  def posted(**options)
    ask(**options)
    assert_response :created
    [ AgentLoginRequest.find_by!(slug: body.dig("data", "slug")), body.dig("data", "collect_key") ]
  end

  def collect(login, key, headers: @legacy)
    post "/api/v1/agent_login_requests/#{login.slug}/collect", params: { collect_key: key, harness_session_id: HARNESS },
                                                               headers: headers, as: :json
  end

  # A granted key: the AgentSession row.
  def granted_key(label: "studio-mac")
    AgentSession.grant_harness_key!(label: label, issued_by: "operator_grant")
  end

  def mint(headers, soul: "pokemon", task: @task, **extra)
    post api_v1_agent_sessions_path, params: { soul: soul, task_slug: task.slug, **extra }, headers: headers, as: :json
  end

  # ---- the grant ---------------------------------------------------------------

  test "a harness key request is held as the machine, whatever soul the caller names" do
    login, key = posted

    assert_equal %w[harness_key studio-mac pokemon pending], [ login.kind, login.label, login.soul, body.dig("data", "status") ]
    assert key.present?
    assert_not_includes response.body, login.code
  end

  test "a harness key request names a machine" do
    ask(label: nil)
    assert_response :unprocessable_entity
    assert_match(/names the machine/, body["error"])

    ask(label: "<script>")
    assert_response :unprocessable_entity
  end

  test "the Approve tap grants a key the requester collects once" do
    login, key = posted
    log_in_as(users(:alex))
    get tasks_path
    assert_select "#admin-login-#{login.slug} [data-test='harness-key-request']", text: "Harness key · studio-mac"

    assert_difference -> { AgentSession.where(tier: "harness").count }, 1 do
      post approve_agent_login_path(login.slug), as: :json
    end
    assert_response :ok
    assert_not_includes response.body, "token"

    collect(login, key)
    assert_response :ok
    held = AgentSession.from_token(body.dig("data", "token"))
    assert_equal [ "harness", "pokemon", "studio-mac", "operator_grant", nil ],
                 [ held.tier, held.soul, held.label, held.issued_by, held.task_slug ]
    assert held.expires_at > 50.years.from_now, "a harness key carries no expiry in effect"

    collect(login, key)
    assert_response :gone
  end

  test "the one-time code grants a key with no tap" do
    login, key = posted
    post "/api/v1/agent_login_requests/#{login.slug}/code",
         params: { collect_key: key, harness_session_id: HARNESS, code: login.code }, headers: @legacy, as: :json

    assert_response :ok
    assert_equal "launch_phrase", AgentSession.find_by!(slug: body.dig("data", "agent_session_slug")).issued_by
  end

  test "no session asks for a harness key: a studio, an admin or a client session cannot mint one for any machine" do
    assert_no_difference -> { AgentLoginRequest.count } do
      [ @studio, @admin ].each do |session|
        ask(bearer(session), label: "other-mac")
        assert_response :forbidden
        assert_match(/a session cannot mint a session/, body["error"])
      end
      ask(bearer(@client), label: "other-mac")
      assert_response :forbidden
    end

    # Control: the machine credential asks, and a held key asks for a machine's next one.
    ask
    assert_response :created
    ask(bearer(granted_key), label: "other-mac", harness: "harness-two")
    assert_response :created
  end

  test "a studio session cannot collect another machine's granted key" do
    login, key = posted
    login.approve!(by: "alex@mcritchie.studio")

    collect(login, key, headers: bearer(@studio))
    assert_response :forbidden
    post "/api/v1/agent_login_requests/#{login.slug}/collect", params: { collect_key: "guess", harness_session_id: HARNESS },
                                                               headers: @legacy, as: :json
    assert_response :forbidden

    collect(login, key)
    assert_response :ok
  end

  # ---- what the key reaches ----------------------------------------------------

  test "harness key mints studio" do
    key = granted_key
    assert_difference -> { AgentSession.where(tier: "studio").count }, 1 do
      mint(bearer(key), harness_session_id: "harness-1")
    end

    assert_response :created
    session = AgentSession.from_token(body.dig("data", "token"))
    assert_equal [ "pokemon", "studio", @task.slug, "task_claim" ], [ session.soul, session.tier, session.task_slug, session.issued_by ]

    # The login it minted writes its own task; the key does not.
    patch api_v1_task_path(@task.slug), params: { title: "Renamed By Its Builder" }, headers: bearer(session), as: :json
    assert_response :ok
  end

  test "harness key cannot mint admin" do
    key = granted_key
    assert_no_difference -> { AgentSession.where.not(tier: "studio").count } do
      %w[admin client harness].each do |tier|
        mint(bearer(key), soul: "xan", tier: tier)
        assert_response :forbidden, tier
        assert_match(/granted by the operator/, body["error"])
      end
    end

    # A request for an admin login mints nothing by itself: it waits for the operator.
    assert_no_difference -> { AgentSession.count } do
      post "/api/v1/agent_login_requests", params: { soul: "xan", harness_session_id: HARNESS }, headers: bearer(key), as: :json
    end
    assert_response :created
    assert_equal "pending", body.dig("data", "status")
  end

  test "a harness key mints only the login the task record entitles" do
    key = granted_key
    assert_no_difference -> { AgentSession.count } do
      mint(bearer(key), soul: "carl")
      assert_response :forbidden
      assert_match(/is not #{@task.slug}'s builder/, body["error"])

      mint(bearer(key), task: tasks(:queued_task))
      assert_response :conflict
    end
  end

  test "harness key reaches only mint doors" do
    key = granted_key
    calls = {
      "read the board" => -> { get api_v1_tasks_path, headers: bearer(key) },
      "read a task" => -> { get api_v1_task_path(@task.slug), headers: bearer(key) },
      "write a task" => -> { patch api_v1_task_path(@task.slug), params: { title: "Renamed By A Key" }, headers: bearer(key), as: :json },
      "create a task" => -> { post api_v1_tasks_path, params: { title: "Made By A Key" }, headers: bearer(key), as: :json },
      "narrate" => -> { post "/api/v1/activities", params: { activity: { agent_slug: "xan", activity_type: "note" } }, headers: bearer(key), as: :json },
      "release a review claim" => -> { post review_claim_release_api_v1_task_path(@task.slug), params: { session: "s", nonce: "n" }, headers: bearer(key), as: :json },
      "log out" => -> { delete "/api/v1/agent_sessions/current", headers: bearer(key) }
    }
    assert_no_difference [ -> { Task.count }, -> { Activity.count } ] do
      calls.each do |name, call|
        call.call
        assert_response :forbidden, name
        assert_equal "SESSION_FORBIDDEN", body["error_code"], name
        assert_match(/a harness key mints studio logins/, body["error"], name)
      end
    end
    assert_equal "In Progress Task", @task.reload.title

    # Control: the shared token still reads and writes.
    get api_v1_tasks_path, headers: @legacy
    assert_response :ok
    patch api_v1_task_path(@task.slug), params: { title: "Renamed By The Shared Token" }, headers: @legacy, as: :json
    assert_response :ok
  end

  test "a harness key takes a review claim, which logs the reviewer in" do
    task = Task.create!(title: "Reviewed From A Keyed Machine", stage: "submitted")
    task.update_column(:metadata, { "devops" => { "built_by" => "pokemon", "builders" => [ "pokemon" ] } })

    post review_claim_api_v1_task_path(task.slug), params: { session: "rev-1", nonce: "n", reviewer: "carl" },
                                                   headers: bearer(granted_key), as: :json

    assert_response :ok
    login = body.dig("data", "agent_session")
    assert_equal %w[carl studio review_claim], login.values_at("soul", "tier", "issued_by")
    assert AgentSession.from_token(login["token"]).live?
  end

  test "a revoked harness key answers 401 with the reason and mints nothing" do
    key = granted_key
    key.revoke!(by: "alex@mcritchie.studio")

    assert_no_difference -> { AgentSession.count } do
      mint(bearer(key))
    end
    assert_response :unauthorized
    assert_equal "SESSION_ENDED", body["error_code"]
    assert_match(/was revoked by alex@mcritchie.studio/, body["error"])

    # Control: the shared token still mints.
    mint(@legacy)
    assert_response :created
  end

  test "the key names itself and never a session" do
    key = granted_key
    get "/api/v1/agent_sessions/current", headers: bearer(key)

    assert_response :ok
    assert_equal [ "harness_key", nil, key.slug ], [ body.dig("data", "auth"), body.dig("data", "session"), body.dig("data", "harness_key", "slug") ]
    assert_not_includes response.body, key.token
  end

  test "the mint is logged by key slug and machine, never the key" do
    key = granted_key
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    begin
      mint(bearer(key))
    ensure
      Rails.logger = original
    end

    assert_includes io.string, "[agent-auth] harness key #{key.slug} (studio-mac): POST /api/v1/agent_sessions"
    assert_not_includes io.string, key.token
  end
end
