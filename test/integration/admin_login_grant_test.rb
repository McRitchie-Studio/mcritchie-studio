require "test_helper"

# [integration] The admin login grant, end to end: the request, the two grant
# paths (the board's Approve tap and the one-time code), and the single collect.
# Each refusal carries its control: the legitimate caller succeeds.
class AdminLoginGrantTest < ActionDispatch::IntegrationTest
  HARNESS = "harness-one".freeze

  setup do
    @legacy = { "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}" }
    @studio = AgentSession.issue_studio!(soul: "jasper", task: tasks(:in_progress_task), issued_by: "task_claim")
    @admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
    @client = AgentSession.create!(soul: "tyrion", tier: "client", issued_by: "runtime_key")
  end

  def bearer(session) = { "Authorization" => "Bearer #{session.token}" }
  def body = JSON.parse(response.body)

  def ask(headers = @legacy, soul: "xan", harness: HARNESS)
    post "/api/v1/agent_login_requests", params: { soul: soul, harness_session_id: harness }, headers: headers, as: :json
  end

  # A posted request: [the row, its collect key].
  def posted(**options)
    ask(**options)
    assert_response :created
    [ AgentLoginRequest.find_by!(slug: body.dig("data", "slug")), body.dig("data", "collect_key") ]
  end

  def collect(login, key, headers: @legacy, harness: HARNESS)
    post "/api/v1/agent_login_requests/#{login.slug}/collect", params: { collect_key: key, harness_session_id: harness },
                                                               headers: headers, as: :json
  end

  def send_code(login, key, code, headers: @legacy, harness: HARNESS)
    post "/api/v1/agent_login_requests/#{login.slug}/code",
         params: { collect_key: key, harness_session_id: harness, code: code }, headers: headers, as: :json
  end

  def approve(login) = post(approve_agent_login_path(login.slug), as: :json)

  # ---- the request ------------------------------------------------------------

  test "the machine credential posts a request and the response carries no code" do
    login, key = posted

    assert_equal %w[xan pending], [ login.soul, body.dig("data", "status") ]
    assert key.present?
    assert_not_includes response.body, login.code
    assert_not_includes response.body, login.display_code
  end

  test "no session, and no unauthenticated caller, posts a request" do
    assert_no_difference -> { AgentLoginRequest.count } do
      [ @studio, @admin ].each do |session|
        ask(bearer(session))
        assert_response :forbidden
        assert_match(/a session cannot mint a session/, body["error"])
      end
      ask(bearer(@client))
      assert_response :forbidden
      ask({})
      assert_response :unauthorized
    end
  end

  test "a request names an admin soul and a harness session" do
    ask(soul: "carl")
    assert_response :unprocessable_entity
    assert_match(/holds no admin tier/, body["error"])

    ask(harness: "")
    assert_response :unprocessable_entity
    assert_match(/harness_session_id is required/, body["error"])
  end

  test "the sixth open request answers 429" do
    AgentLoginRequest::PENDING_CAP.times { |n| posted(harness: "harness-#{n}") }

    ask(harness: "harness-over")
    assert_response :too_many_requests
    assert_equal "TOO_MANY_PENDING", body["error_code"]
  end

  # ---- path 2: the Approve tap -------------------------------------------------

  test "approve tap mints" do
    login, key = posted
    log_in_as(users(:alex))

    assert_difference -> { AgentSession.where(tier: "admin", issued_by: "operator_grant").count }, 1 do
      approve(login)
    end
    assert_response :ok
    assert_equal "granted", body.dig("data", "status")
    assert_not_includes response.body, "token"
    session = login.reload.agent_session
    assert_nil session.task_slug
    assert_equal users(:alex).email, login.decided_by

    get logout_path
    collect(login, key)
    assert_response :ok
    assert_equal session, AgentSession.from_token(body.dig("data", "token"))
  end

  test "no bearer and no non-admin approves or declines a request" do
    login, = posted

    assert_no_difference -> { AgentSession.count } do
      [ bearer(@studio), bearer(@admin), bearer(@client), @legacy, {} ].each do |headers|
        %w[approve refuse].each do |action|
          post "/agent_logins/#{login.slug}/#{action}", headers: headers, as: :json
          assert_response :unauthorized, "#{action} with #{headers.keys}"
        end
      end

      log_in_as(users(:viewer))
      approve(login)
      assert_response :forbidden
      post refuse_agent_login_path(login.slug), as: :json
      assert_response :forbidden
    end
    assert_equal "pending", login.reload.status
  end

  test "a declined request answers the tap and the collect with the reason" do
    login, key = posted
    log_in_as(users(:alex))

    post refuse_agent_login_path(login.slug), as: :json
    assert_response :ok
    assert_no_difference -> { AgentSession.count } do
      approve(login)
      assert_response :conflict
      assert_match(/was refused: declined by the operator/, body["error"])
    end

    collect(login, key)
    assert_response :gone
    assert_equal "LOGIN_REFUSED", body["error_code"]
    assert_match(/declined by the operator/, body["error"])
  end

  test "an unknown request answers 404" do
    log_in_as(users(:alex))
    post approve_agent_login_path("login-nobody"), as: :json
    assert_response :not_found

    collect(AgentLoginRequest.new(slug: "login-nobody"), "k")
    assert_response :not_found
  end

  # ---- path 1: the one-time code ----------------------------------------------

  test "the code grants with no approve tap" do
    login, key = posted

    assert_difference -> { AgentSession.where(tier: "admin", issued_by: "launch_phrase").count }, 1 do
      send_code(login, key, login.display_code)
    end
    assert_response :ok
    assert_not_includes response.body, "token"

    collect(login, key)
    assert_response :ok
    session = AgentSession.from_token(body.dig("data", "token"))
    assert_equal [ "admin", "xan", nil ], [ session.tier, session.soul, session.task_slug ]
  end

  test "a wrong, reused or lapsed code answers 4xx with the reason and grants nothing" do
    login, key = posted
    code = login.display_code

    assert_no_difference -> { AgentSession.count } do
      send_code(login, key, "AAAA-AAAA")
      assert_response :forbidden
      assert_equal "WRONG_CODE", body["error_code"]
      assert_match(/4 of 5 attempts left/, body["error"])

      send_code(login, key, "")
      assert_response :forbidden

      travel 11.minutes do
        send_code(login, key, code)
        assert_response :gone
        assert_equal "LOGIN_LAPSED", body["error_code"]
      end
    end

    send_code(login, key, code) # control: the right code, inside the window
    assert_response :ok
    assert_no_difference -> { AgentSession.count } do
      send_code(login, key, code)
      assert_response :conflict
      assert_equal "LOGIN_DECIDED", body["error_code"]
    end
  end

  test "the code is refused without the requester's key, and from any session" do
    login, key = posted
    code = login.display_code

    assert_no_difference -> { AgentSession.count } do
      send_code(login, "guess", code)
      assert_response :forbidden
      assert_equal "LOGIN_FORBIDDEN", body["error_code"]
      send_code(login, key, code, harness: "another-harness")
      assert_response :forbidden
      [ @studio, @admin, @client ].each do |session|
        send_code(login, key, code, headers: bearer(session))
        assert_response :forbidden
      end
      send_code(login, key, code, headers: {})
      assert_response :unauthorized
    end
    assert_equal 0, login.reload.code_attempts
  end

  # ---- the collect ------------------------------------------------------------

  test "collect returns the token once, to the harness that asked" do
    login, key = posted
    login.approve!(by: "alex@test.com")

    collect(login, "guess")
    assert_response :forbidden
    collect(login, key, harness: "another-harness")
    assert_response :forbidden
    [ @studio, @admin, @client ].each do |session|
      collect(login, key, headers: bearer(session))
      assert_response :forbidden
    end
    collect(login, key, headers: {})
    assert_response :unauthorized
    assert_nil login.reload.collected_at

    collect(login, key)
    assert_response :ok
    assert body.dig("data", "token").present?

    collect(login, key)
    assert_response :gone
    assert_equal "LOGIN_COLLECTED", body["error_code"]
    assert_nil body["data"]
  end

  test "a pending collect answers 409 and a lapsed one 410" do
    login, key = posted

    collect(login, key)
    assert_response :conflict
    assert_equal "LOGIN_PENDING", body["error_code"]

    travel 11.minutes do
      collect(login, key)
      assert_response :gone
      assert_match(/nothing was minted/, body["error"])
    end
    assert_equal 0, AgentSession.where(harness_session_id: HARNESS).count
  end

  # ---- the board --------------------------------------------------------------

  test "the board shows the code and the taps to an admin only" do
    login, = posted
    code = login.display_code

    log_in_as(users(:alex))
    [ tasks_path, deployments_path ].each do |path|
      get path
      assert_response :ok
      assert_select "#admin-login-#{login.slug} [data-test='admin-login-code']", text: code
      assert_select "#admin-login-#{login.slug} [data-test='admin-login-approve'][data-url='#{approve_agent_login_path(login.slug)}']"
      assert_select "#admin-login-#{login.slug} [data-test='task-window-chip'][data-window-kind='admin_login']"
    end

    travel 11.minutes do
      get tasks_path
      assert_select "[data-test='admin-login-request']", 0
    end
  end

  test "no API read and no non-admin page carries the code" do
    login, = posted
    code = login.display_code

    [ @legacy, bearer(@studio), bearer(@admin) ].each do |headers|
      get "/api/v1/agent_sessions/current", headers: headers
      assert_not_includes response.body, code
      get "/api/v1/agent_login_requests/#{login.slug}", headers: headers
      assert_response :not_found
    end

    get tasks_path
    assert_redirected_to login_path
    log_in_as(users(:viewer))
    get tasks_path
    assert_not_includes response.body.to_s, code
    assert_not_includes response.body.to_s, login.slug
  end
end
