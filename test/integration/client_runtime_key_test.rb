require "test_helper"
require "rake"

# [integration] Turf Monster's runtime key: a client session with no expiry in
# effect that reaches the athletes read and the game recap post, and nothing else.
# The shared secret's token keeps reaching both (the control) until Turf's config
# is swapped.
class ClientRuntimeKeyTest < ActionDispatch::IntegrationTest
  setup do
    @legacy = { "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}" }
    @key = AgentSession.grant_runtime_key!(soul: "turf-monster", label: "turf-production")
    @task = tasks(:in_progress_task)
  end

  def bearer(session) = { "Authorization" => "Bearer #{session.token}" }
  def body = JSON.parse(response.body)

  def game
    { game_slug: "buffalo-bills-vs-miami-dolphins", home_team_slug: teams(:buffalo_bills).slug,
      away_team_slug: teams(:miami_dolphins).slug, home_score: 24, away_score: 17, status_detail: "Final",
      season_year: 2026, season_type: 2, week: 3 }
  end

  def post_recap(headers) = post(api_v1_game_recaps_path, params: { game: game }, headers: headers, as: :json)

  test "test_client_key_reaches_only_its_two_endpoints" do
    get "/api/v1/athletes", headers: bearer(@key)
    assert_response :ok
    assert_difference -> { Content.count }, 1 do
      post_recap(bearer(@key))
    end
    assert_response :created

    # Control: the same key on the board answers 403 and names what it reaches.
    calls = {
      "read the board" => -> { get api_v1_tasks_path, headers: bearer(@key) },
      "read a task" => -> { get api_v1_task_path(@task.slug), headers: bearer(@key) },
      "write a task" => -> { patch api_v1_task_path(@task.slug), params: { title: "Renamed By Turf" }, headers: bearer(@key), as: :json },
      "mint a login" => -> { post api_v1_agent_sessions_path, params: { soul: "pokemon", task_slug: @task.slug }, headers: bearer(@key), as: :json },
      "ask for a harness key" => -> { post "/api/v1/agent_login_requests", params: { kind: "harness_key", label: "turf", harness_session_id: "h" }, headers: bearer(@key), as: :json },
      "narrate" => -> { post "/api/v1/activities", params: { activity: { agent_slug: "xan", activity_type: "note" } }, headers: bearer(@key), as: :json },
      "who am I" => -> { get "/api/v1/agent_sessions/current", headers: bearer(@key) }
    }
    assert_no_difference [ -> { AgentSession.count }, -> { Activity.count }, -> { AgentLoginRequest.count } ] do
      calls.each do |name, call|
        call.call
        assert_response :forbidden, name
        assert_equal "SESSION_FORBIDDEN", body["error_code"], name
        assert_match(%r{turf-monster's runtime key reaches GET /api/v1/athletes and POST /api/v1/game_recaps and nothing else}, body["error"], name)
      end
    end
    assert_equal "In Progress Task", @task.reload.title
  end

  test "the shared secret's token still reaches both Turf endpoints" do
    get "/api/v1/athletes", headers: @legacy
    assert_response :ok
    post_recap(@legacy)
    assert_response :created
  end

  test "a runtime key carries no expiry in effect and is revoked at once" do
    assert @key.expires_at > 50.years.from_now
    assert_equal [ "client", "runtime_key", "turf-production" ], [ @key.tier, @key.issued_by, @key.label ]

    @key.revoke!(by: "steffon")
    get "/api/v1/athletes", headers: bearer(@key)
    assert_response :unauthorized
    assert_equal "SESSION_ENDED", body["error_code"]
    assert_match(/was revoked by steffon/, body["error"])
  end

  test "a client soul with no endpoints reaches neither Turf endpoint" do
    tyrion = AgentSession.create!(soul: "tyrion", tier: "client", issued_by: "runtime_key")

    get "/api/v1/athletes", headers: bearer(tyrion)
    assert_response :forbidden
    assert_equal "a client session reaches no board endpoint", body["error"]
    assert_no_difference -> { Content.count } do
      post_recap(bearer(tyrion))
    end
    assert_response :forbidden
  end

  test "only a client soul with endpoints is granted a runtime key, and it names its runtime" do
    %w[tyrion carl xan nobody].each do |soul|
      assert_raises(ArgumentError, soul) { AgentSession.grant_runtime_key!(soul: soul, label: "x") }
    end
    assert_raises(ArgumentError) { AgentSession.grant_runtime_key!(soul: "turf-monster", label: " ") }
  end

  # ---- the operator's rakes ----------------------------------------------------

  def rake(name, env = {})
    Rails.application.load_tasks unless Rake::Task.task_defined?("agent_sessions:grant_runtime_key")
    Rake::Task[name].reenable
    before = env.to_h { |k, _| [ k, ENV[k] ] }
    env.each { |k, v| ENV[k] = v }
    status = 0
    out, err = capture_io do
      Rake::Task[name].invoke
    rescue SystemExit => e
      status = e.status
    end
    [ out, err, status ]
  ensure
    before&.each { |k, v| ENV[k] = v }
  end

  test "grant_runtime_key prints only the key on stdout, and keys lists it without a value" do
    out, err, status = rake("agent_sessions:grant_runtime_key", "SOUL" => "turf-monster", "LABEL" => "turf-qa")
    key = AgentSession.from_token(out.strip)

    assert_equal [ 0, 1 ], [ status, out.lines.size ]
    assert_equal %w[turf-monster client runtime_key turf-qa], [ key.soul, key.tier, key.issued_by, key.label ]
    assert_match(/#{key.slug}.*length #{out.strip.length}/, err)
    refute_includes err, out.strip

    harness = AgentSession.grant_harness_key!(label: "studio-mac", issued_by: "operator_grant")
    listed, = rake("agent_sessions:keys")
    [ key, harness, @key ].each { |row| assert_includes listed, row.slug }
    assert_includes listed, "studio-mac"
    [ key, harness, @key ].each { |row| refute_includes listed, row.token }

    _, err, status = rake("agent_sessions:grant_runtime_key", "SOUL" => "turf-monster", "LABEL" => "")
    assert_equal 1, status
    assert_match(/LABEL is required/, err)
  end

  test "revoke ends a key by slug and names an unknown one" do
    out, _, status = rake("agent_sessions:revoke", "SLUG" => @key.slug, "BY" => "steffon")
    assert_equal 0, status
    assert_match(/#{@key.slug} .* is revoked/, out)
    assert_equal "steffon", @key.reload.revoked_by

    _, err, status = rake("agent_sessions:revoke", "SLUG" => @key.slug)
    assert_equal 1, status
    assert_match(/already revoked/, err)
    _, err, status = rake("agent_sessions:revoke", "SLUG" => "sess-nope")
    assert_equal 1, status
    assert_match(/no agent session "sess-nope"/, err)
  end
end
