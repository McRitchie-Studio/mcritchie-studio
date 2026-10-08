require "test_helper"
require "rake"

# [integration] The legacy-use census: every request the shared secret
# authenticates is counted by endpoint and caller, a request under a login is not,
# and the count never holds a credential. The shared token keeps passing what it
# passes today (the controls).
class LegacyAuthCensusTest < ActionDispatch::IntegrationTest
  setup do
    @token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @legacy = { "Authorization" => "Bearer #{@token}" }
    @task = tasks(:in_progress_task)
    @task.update_column(:metadata, @task.metadata.to_h.merge("devops" => { "built_by" => "pokemon", "builders" => [ "pokemon" ] }))
  end

  def bearer(session) = { "Authorization" => "Bearer #{session.token}" }
  def uses(endpoint, caller) = LegacyAuthUse.where(endpoint: endpoint, caller: caller).sum(:uses)

  test "a shared-token request is counted by endpoint and caller, and still passes" do
    2.times { get api_v1_tasks_path, headers: @legacy.merge("X-Agent-Caller" => "bin/task") }
    assert_response :ok
    patch api_v1_task_path(@task.slug), params: { title: "Renamed Under The Shared Token" },
                                        headers: @legacy.merge("X-Agent-Caller" => "bin/task"), as: :json
    assert_response :ok
    get "/api/v1/athletes", headers: @legacy.merge("X-Agent-Caller" => "turf-monster/sync_athletes")
    assert_response :ok

    assert_equal 2, uses("GET api/v1/tasks#index", "bin/task")
    assert_equal 1, uses("PATCH api/v1/tasks#update", "bin/task")
    assert_equal 1, uses("GET api/v1/athletes#index", "turf-monster/sync_athletes")
    assert_equal 1, LegacyAuthUse.where(endpoint: "GET api/v1/tasks#index").count, "one row per day, endpoint and caller"
    assert_in_delta Time.current, LegacyAuthUse.maximum(:last_used_at), 5.seconds
  end

  test "an exchange of the secret is counted too" do
    secret = "census-secret"
    Rails.application.credentials.stub(:agent_api_secret, secret) do
      post "/api/v1/auth", params: { secret: secret }, headers: { "X-Agent-Caller" => "bin/submit" }, as: :json
      assert_response :ok
      assert_no_difference -> { LegacyAuthUse.sum(:uses) } do
        post "/api/v1/auth", params: { secret: "wrong" }, as: :json
        assert_response :unauthorized
      end
    end

    assert_equal 1, uses("POST api/v1/auth#create", "bin/submit")
  end

  test "a request under a login, a harness key or a runtime key is not a legacy use" do
    studio = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")
    harness = AgentSession.grant_harness_key!(label: "studio-mac", issued_by: "operator_grant")
    turf = AgentSession.grant_runtime_key!(soul: "turf-monster", label: "turf-production")

    assert_no_difference -> { LegacyAuthUse.sum(:uses) } do
      patch api_v1_task_path(@task.slug), params: { title: "Renamed Under A Login" }, headers: bearer(studio), as: :json
      assert_response :ok
      get "/api/v1/agent_sessions/current", headers: bearer(harness)
      assert_response :ok
      get "/api/v1/athletes", headers: bearer(turf)
      assert_response :ok
      get api_v1_tasks_path
      assert_response :unauthorized
    end
  end

  test "an unlabelled or malformed caller is counted without being trusted" do
    get api_v1_tasks_path, headers: @legacy.merge("User-Agent" => "Ruby")
    get api_v1_tasks_path, headers: @legacy.merge("X-Agent-Caller" => "<script>alert(1)</script>", "User-Agent" => "curl/8.4.0")
    get api_v1_tasks_path, headers: @legacy.merge("X-Agent-Caller" => "x" * 200, "User-Agent" => "")

    assert_equal [ "unlabelled", "unlabelled (Ruby)", "unlabelled (curl)" ], LegacyAuthUse.pluck(:caller).sort
  end

  test "the census holds no token and no secret" do
    get api_v1_tasks_path, headers: @legacy.merge("X-Agent-Caller" => "bin/task")

    stored = LegacyAuthUse.all.map { |row| row.attributes.values.join(" ") }.join(" ")
    assert_not_includes stored, @token
    assert_equal %w[caller day endpoint id last_used_at uses], LegacyAuthUse.column_names.sort
  end

  test "a census that cannot be written never fails the request it counts" do
    LegacyAuthUse.stub(:upsert, ->(*, **) { raise ActiveRecord::StatementInvalid, "boom" }) do
      get api_v1_tasks_path, headers: @legacy
    end

    assert_response :ok
  end

  # ---- the operator's read -----------------------------------------------------

  def census(env = {})
    Rails.application.load_tasks unless Rake::Task.task_defined?("agent_auth:legacy_census")
    Rake::Task["agent_auth:legacy_census"].reenable
    before = env.to_h { |k, _| [ k, ENV[k] ] }
    env.each { |k, v| ENV[k] = v }
    status = 0
    out, err = capture_io do
      Rake::Task["agent_auth:legacy_census"].invoke
    rescue SystemExit => e
      status = e.status
    end
    [ out, err, status ]
  ensure
    before&.each { |k, v| ENV[k] = v }
  end

  test "the rake prints ZERO when the period has no legacy use" do
    LegacyAuthUse.record!(endpoint: "GET api/v1/tasks#index", caller: "bin/task", now: 10.days.ago)
    out, = census

    assert_includes out, "last 7 day(s) (UTC): 0 request(s), 0 outside the mint doors"
    assert_includes out, "ZERO: no request outside the mint doors was authenticated by the shared secret in this period."
  end

  test "a use at a mint door does not hold the gate open, and any other use does" do
    LegacyAuthUse::MINT_DOORS.each { |door| LegacyAuthUse.record!(endpoint: door, caller: "bin/task") }
    out, = census
    assert_includes out, "#{LegacyAuthUse::MINT_DOORS.size} request(s), 0 outside the mint doors"
    assert_match(/^ZERO: /, out)
    assert_no_match(/\*/, out)

    LegacyAuthUse.record!(endpoint: "PATCH api/v1/tasks#update", caller: "bin/task")
    out, = census
    assert_includes out, "1 outside the mint doors"
    assert_match(/^NOT ZERO: 1 request/, out)
    assert_match(/1 \* PATCH api\/v1\/tasks#update/, out)
  end

  test "every mint door is a real action, and every action a harness key may POST is a mint door" do
    posts = Rails.application.routes.routes.select { |r| r.verb == "POST" }
                 .map { |r| "POST #{r.defaults[:controller]}##{r.defaults[:action]}" }
    LegacyAuthUse::MINT_DOORS.each { |door| assert_includes posts, door }

    keyed = [ Api::V1::AgentSessionsController, Api::V1::TaskReviewClaimsController, Api::V1::AgentLoginRequestsController ]
            .flat_map { |c| c.harness_key_actions.map { |action| "POST #{c.controller_path}##{action}" } }
    assert_empty (keyed & posts) - LegacyAuthUse::MINT_DOORS
  end

  test "the rake prints uses by endpoint and caller, the busiest first, and per day" do
    3.times { LegacyAuthUse.record!(endpoint: "POST api/v1/agent_actions#create", caller: "bin/atomic-capture-hook") }
    LegacyAuthUse.record!(endpoint: "GET api/v1/athletes#index", caller: "turf-monster/sync_athletes", now: 2.days.ago)
    out, = census

    lines = out.lines.map(&:strip)
    assert_includes lines.first, "4 request(s), 4 outside the mint doors"
    assert_match(/\A3 \* POST api\/v1\/agent_actions#create\s+bin\/atomic-capture-hook\s+last /, lines[2])
    assert_match(/\A1 \* GET api\/v1\/athletes#index\s+turf-monster\/sync_athletes/, lines[3])
    assert_match(/By day: .*#{2.days.ago.utc.to_date} 1 · #{1.day.ago.utc.to_date} 0 · #{Time.current.utc.to_date} 3\z/, lines.last)

    _, err, status = census("DAYS" => "soon")
    assert_equal 1, status
    assert_match(/DAYS must be a whole number/, err)
  end
end
