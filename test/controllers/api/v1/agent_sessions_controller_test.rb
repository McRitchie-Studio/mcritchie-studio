require "test_helper"

# [integration] The board API authenticates through an agent session: a studio
# login at the claim, writes that stamp the actor from the session, the tier and
# scope gates, and the refusals (revoked, expired, task moved on) as 401 with the
# reason. The shared secret's token keeps working beside it (the control).
module Api
  module V1
    class AgentSessionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @task = tasks(:in_progress_task) # building
        # The claim stamped pokemon as the builder, so pokemon is the soul a
        # task_claim login is entitled to.
        @task.update_column(:metadata, @task.metadata.to_h.merge("devops" => { "built_by" => "pokemon",
                                                                                "builders" => ["pokemon"] }))
        @other = tasks(:queued_task)
        @legacy = { "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}" }
      end

      def bearer(session) = { "Authorization" => "Bearer #{session.token}" }

      def login(soul: "pokemon", task: @task, headers: @legacy, **extra)
        post api_v1_agent_sessions_path, params: { soul: soul, task_slug: task.slug, **extra }, headers: headers, as: :json
      end

      def checkpoint(task, headers, actor: "carl")
        post "/api/v1/tasks/#{task.slug}/events/fast_check/start",
             params: { event: { actor: actor } }, headers: headers, as: :json
      end

      def error = JSON.parse(response.body)["error"]

      def capture_log
        io = StringIO.new
        original = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)
        yield
        io.string
      ensure
        Rails.logger = original
      end

      test "a studio login at the claim mints a scoped session token" do
        assert_difference -> { AgentSession.count }, 1 do
          login(harness_session_id: "harness-1")
        end

        assert_response :created
        data = JSON.parse(response.body)["data"]
        session = AgentSession.find_by!(slug: data["slug"])
        assert_equal ["pokemon", "studio", @task.slug, "task_claim", "harness-1"],
                     [session.soul, session.tier, session.task_slug, session.issued_by, session.harness_session_id]
        assert_equal session, AgentSession.from_token(data.fetch("token"))
      end

      test "a task write with a session stamps the session's soul, not the actor param" do
        session = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")

        checkpoint(@task, bearer(session), actor: "carl")

        assert_response :created
        assert_equal "pokemon", @task.task_events.last.actor
      end

      # The control for the test above: the same write with the shared secret's
      # token keeps the self-declared actor, so the stamp above is the session's doing.
      test "the shared secret's token still works and keeps the actor param" do
        checkpoint(@task, @legacy, actor: "carl")

        assert_response :created
        assert_equal "carl", @task.task_events.last.actor
      end

      test "a studio session cannot write a task it is not scoped to" do
        session = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")

        checkpoint(@other, bearer(session))

        assert_response :forbidden
        assert_match(/scoped to #{@task.slug}, not #{@other.slug}/, error)
      end

      test "a studio session cannot call an admin endpoint" do
        session = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")

        post api_v1_release_notes_path, params: { task_slugs: [@task.slug] }, headers: bearer(session), as: :json

        assert_response :forbidden
        assert_match(/needs an admin session; pokemon holds a studio session/, error)
      end

      # Carl's gap on phase one: the refusal above must not catch the shared token. A
      # legacy bearer carries no session, so an admin-only release endpoint still
      # serves it for the one release it stays accepted.
      test "the shared token still reaches an admin-only release endpoint" do
        release = Release.open!
        path = "/api/v1/releases/#{release.slug}/events/ship_gate/start"

        assert_difference -> { ReleaseEvent.count }, 1 do
          post path, params: { event: { actor: "avi" } }, headers: @legacy, as: :json
        end
        assert_response :created
        assert_equal "avi", release.release_events.last.actor

        # The control: the same call with a studio session is refused.
        session = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")
        assert_no_difference -> { ReleaseEvent.count } do
          post path, params: { event: { actor: "avi" } }, headers: bearer(session), as: :json
        end
        assert_response :forbidden
      end

      # A desk that dropped its session falls back to the shared token and names the
      # dropped slug (bin/lib/desk_session.rb), so the legacy log line points at the desk.
      test "a legacy-token log line names the dropped desk session, and ignores a header that is not a slug" do
        lines = capture_log do
          checkpoint(@task, @legacy.merge("X-Agent-Session-Dropped" => "sess-0123abcd"))
          checkpoint(@task, @legacy)
          checkpoint(@task, @legacy.merge("X-Agent-Session-Dropped" => "x\n[agent-auth] forged"))
        end.lines.grep(/\[agent-auth\] legacy/)

        assert_equal 3, lines.size, lines.inspect
        assert_includes lines[0], "(dropped desk session sess-0123abcd)"
        refute_includes lines[1], "dropped desk session"
        refute_includes lines[2], "dropped desk session"
        refute_includes lines[2], "forged"
      end

      test "an admin session is unscoped: it writes any task" do
        session = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")

        checkpoint(@other, bearer(session), actor: "carl")

        assert_response :created
        assert_equal "steffon", @other.task_events.last.actor
      end

      test "a revoked session is refused with the reason" do
        session = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")
        delete api_v1_agent_sessions_current_path, headers: bearer(session)
        assert_response :success

        checkpoint(@task, bearer(session))

        assert_response :unauthorized
        assert_match(/was revoked by pokemon/, error)
        assert_equal "SESSION_ENDED", JSON.parse(response.body)["error_code"]
      end

      test "an expired session answers 401 with the reason" do
        session = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")

        travel 25.hours do
          checkpoint(@task, bearer(session))
        end

        assert_response :unauthorized
        assert_match(/expired at/, error)
      end

      test "a studio session ends when its task leaves building and review" do
        session = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")
        @task.update_column(:stage, "reviewed")

        get api_v1_agent_sessions_current_path, headers: bearer(session)

        assert_response :unauthorized
        assert_match(/left building and review/, error)
      end

      test "a client session reaches no board endpoint" do
        session = AgentSession.create!(soul: "tyrion", tier: "client", issued_by: "runtime_key")

        get api_v1_agent_sessions_current_path, headers: bearer(session)

        assert_response :forbidden
      end

      test "a session cannot mint a session" do
        session = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")

        login(headers: bearer(session))

        assert_response :forbidden
        assert_match(/cannot mint a session/, error)
      end

      test "the login refuses an admin tier, a task not in its claim stage, and a non-soul" do
        login(tier: "admin")
        assert_response :forbidden

        login(task: @other) # designed
        assert_response :conflict
        assert_match(/needs #{@other.slug} in building; it is designed/, error)

        login(soul: "nobody")
        assert_response :unprocessable_entity
        assert_match(/not a soul/, error)
      end

      # Phase one minted a session for whatever soul the shared-secret holder named,
      # so any holder could log in as carl. The task record now names who may.
      test "a task_claim login for a soul the claim did not stamp answers 403 with the reason" do
        assert_no_difference -> { AgentSession.count } do
          login(soul: "carl")
        end

        assert_response :forbidden
        assert_equal "SESSION_FORBIDDEN", JSON.parse(response.body)["error_code"]
        assert_match(/carl is not #{@task.slug}'s builder \(the claim recorded pokemon\)/, error)
      end

      test "a review_claim login is for a reviewer the task names, never its builder" do
        @task.update_columns(stage: "submitted",
                             metadata: @task.metadata.merge("reviewers" => [{ "slug" => "carl", "weight" => "primary" }]))

        login(soul: "carl", issued_by: "review_claim")
        assert_response :created

        login(soul: "jasper", issued_by: "review_claim")
        assert_response :forbidden
        assert_match(/jasper is not a reviewer #{@task.slug} names \(carl\)/, error)

        login(soul: "pokemon", issued_by: "review_claim")
        assert_response :forbidden
        assert_match(/pokemon built #{@task.slug}/, error)
      end

      test "whoami names the session, or legacy for the shared secret's token" do
        session = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")

        get api_v1_agent_sessions_current_path, headers: bearer(session)
        assert_equal "pokemon", JSON.parse(response.body).dig("data", "session", "soul")

        get api_v1_agent_sessions_current_path, headers: @legacy
        assert_equal "legacy", JSON.parse(response.body).dig("data", "auth")
      end

      test "task show carries the logged-in soul" do
        AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")

        get api_v1_task_path(@task.slug), headers: @legacy

        assert_equal "pokemon", JSON.parse(response.body).dig("data", "agent_session", "soul")
      end

      test "task show names only a session that is live" do
        task = Task.create!(title: "Reviewed By A Lapsed Claim", stage: "submitted")
        task.update_column(:metadata, { "devops" => { "built_by" => "pokemon", "builders" => ["pokemon"] } })
        builder = AgentSession.issue_studio!(soul: "pokemon", task: task, issued_by: "task_claim")
        # A reviewer's login whose claim does not exist is unrevoked, unexpired and not live.
        reviewer = AgentSession.issue_studio!(soul: "carl", task: task, issued_by: "review_claim")
        refute reviewer.live?

        get api_v1_task_path(task.slug), headers: @legacy
        assert_equal builder.slug, JSON.parse(response.body).dig("data", "agent_session", "slug"),
                     "the newest session is not live, so the live one behind it is named"

        task.update_column(:stage, "reviewed")
        get api_v1_task_path(task.slug), headers: @legacy
        assert_nil JSON.parse(response.body).dig("data", "agent_session"), "no session is live once the task left review"
      end
    end
  end
end
