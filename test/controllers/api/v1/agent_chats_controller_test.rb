require "test_helper"

module Api
  module V1
    # [integration] The hub side of the shared agent chat (epic agent-chat-primitive,
    # "Contract"): POST /api/v1/agent_chat/messages and GET /api/v1/agent_chat/turns
    # under an app's own bearer credential, with the contract's 201/200 shapes and
    # its 401/404/422/429 refusals.
    class AgentChatsControllerTest < ActionDispatch::IntegrationTest
      ANON = "anon-cookie-token-0001".freeze

      setup do
        AgentMessages::Answerers.current = AgentMessages::Answerers.load
        BuildIntake.reset_policy!
        _row, @secret = AppCredential.issue!(app_slug: "alex-build", purpose: "agent-chat")
      end

      teardown do
        AgentMessages::Answerers.reset!
        BuildIntake.reset_policy!
      end

      def headers(secret = @secret) = { "Authorization" => "Bearer #{secret}" }

      def post_message(text: "What can you build?", soul: "alex", person: { anon_token: ANON }, ip: "203.0.113.4", secret: @secret)
        post api_v1_agent_chat_messages_path, params: { soul: soul, text: text, person: person, ip: ip }.compact,
                                              headers: headers(secret), as: :json
      end

      def get_turns(soul: "alex", person: { anon_token: ANON }, **extra)
        get api_v1_agent_chat_turns_path, params: { soul: soul, person: person, **extra }, headers: headers
      end

      test "POST stores the visitor's message and answers 201 with the user turn" do
        assert_difference -> { AgentMessage.count }, 1 do
          post_message
        end

        assert_response :created
        turn = response.parsed_body["turn"]
        message = AgentMessage.last
        assert_equal({ "id" => message.id, "role" => "user", "text" => "What can you build?", "status" => "pending" },
                     turn.except("created_at"))
        assert_equal message.created_at.iso8601(3), turn["created_at"]
        assert_equal "alex-build", message.envelope["app"]
        assert_equal "chat:alex:anon:#{AgentChat.anon_digest(ANON)}", message.thread_key
      end

      test "GET turns gives each message's user turn and, once answered, the agent turn, with pending" do
        post_message
        first = AgentMessage.last
        post_message(text: "And a second thing")
        second = AgentMessage.last
        first.update!(status: "completed", completed_at: Time.current, response_text: "A web app.")
        second.update!(status: "claimed", claimed_by: "w1", claimed_at: Time.current)

        get_turns
        assert_response :ok
        body = response.parsed_body
        assert_equal true, body["pending"]
        assert_equal [ [ first.id, "user", "answered" ], [ first.id, "agent", "answered" ], [ second.id, "user", "typing" ] ],
                     body["turns"].map { |t| t.values_at("id", "role", "status") }
        assert_equal "A web app.", body["turns"][1]["text"]

        get_turns(after: first.id)
        assert_equal [ second.id ], response.parsed_body["turns"].map { |t| t["id"] }

        second.update!(status: "completed", completed_at: Time.current, response_text: "Sure.")
        get_turns(after: first.id, limit: 1)
        assert_equal false, response.parsed_body["pending"]
        assert_equal %w[user agent], response.parsed_body["turns"].map { |t| t["role"] }
      end

      test "GET turns for a visitor with no thread yet is empty, and another visitor's thread is never read" do
        post_message

        get_turns(person: { anon_token: "someone-else-token-0002" })
        assert_response :ok
        assert_equal({ "turns" => [], "pending" => false }, response.parsed_body)

        get_turns(person: { email: "nobody@example.com" })
        assert_equal({ "turns" => [], "pending" => false }, response.parsed_body)
      end

      test "a signed-in person posting from two apps reads one thread, and their anon thread folds in" do
        user = User.create!(email: "builder@example.com", name: "Builder", role: "viewer")
        post_message(text: "signed out first")
        anon_row = AgentMessage.last

        post_message(text: "signed in now", person: { email: "Builder@example.com", anon_token: ANON })
        assert_response :created
        assert_equal "chat:alex:#{user.id}", anon_row.reload.thread_key

        get_turns(person: { email: user.email })
        assert_equal [ "signed out first", "signed in now" ], response.parsed_body["turns"].map { |t| t["text"] }
      end

      test "401 without a credential, with a wrong one, a revoked one, or an agent session's" do
        post api_v1_agent_chat_messages_path, params: { soul: "alex", text: "hi", person: { anon_token: ANON } }, as: :json
        assert_response :unauthorized

        post_message(secret: "#{@secret}x")
        assert_response :unauthorized

        AppCredential.live.find_each { |row| row.revoke!(by: "test") }
        post_message
        assert_response :unauthorized
        assert_equal "UNAUTHORIZED", response.parsed_body["error_code"]

        legacy = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
        get api_v1_agent_chat_turns_path, params: { soul: "alex", person: { anon_token: ANON } }, headers: headers(legacy)
        assert_response :unauthorized
        assert_equal 0, AgentMessage.count
      end

      test "404 for a soul with no web chat or one the app may not address" do
        post_message(soul: "carl")
        assert_response :not_found
        assert_equal "NO_WEB_CHAT", response.parsed_body["error_code"]

        post_message(soul: "avi")
        assert_response :not_found, "avi has a web chat, but alex-build does not list him"

        _row, turf_secret = AppCredential.issue!(app_slug: "turf-monster", purpose: "agent-chat")
        post_message(secret: turf_secret)
        assert_response :not_found, "an app the allow-list does not name"

        get_turns(soul: "avi")
        assert_response :not_found
        assert_equal 0, AgentMessage.count
      end

      test "422 for an empty or long text, a person that names nobody, a bad ip or a bad cursor" do
        post_message(text: "  ")
        assert_response :unprocessable_entity
        assert_equal "EMPTY", response.parsed_body["error_code"]

        post_message(text: "x" * (AgentMessages::WebIngest::MAX_LENGTH + 1))
        assert_equal "TOO_LONG", response.parsed_body["error_code"]

        post_message(person: {})
        assert_response :unprocessable_entity
        post_message(person: { email: "not-an-email" })
        assert_response :unprocessable_entity
        post_message(ip: "not-an-ip")
        assert_response :unprocessable_entity

        get_turns(after: "abc")
        assert_response :unprocessable_entity
        assert_equal 0, AgentMessage.count
      end

      test "the visitor's ip, email and anon token stay out of the request log" do
        filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
        logged = filter.filter("controller" => "api/v1/agent_chats", "ip" => "203.0.113.4",
                               "person" => { "email" => "a@example.com", "anon_token" => ANON })

        assert_equal "[FILTERED]", logged["ip"]
        assert_equal "[FILTERED]", logged["person"]["email"]
        assert_equal "[FILTERED]", logged["person"]["anon_token"]
        assert_equal "203.0.113.4", filter.filter("controller" => "admin/other", "ip" => "203.0.113.4")["ip"],
                     "scoped to the agent chat API"
      end

      test "429 at a cap, with the line the app shows, and nothing stored" do
        BuildIntake.policy = BuildIntake.policy.dup.tap { |p| p.turns_per_request = 1 }
        post_message
        assert_response :created

        assert_no_difference -> { AgentMessage.count } do
          post_message(text: "one more")
        end
        assert_response :too_many_requests
        assert_equal "CAPPED", response.parsed_body["error_code"]
        assert_equal BuildIntake::Caps::REPLIES[:request_signed_out], response.parsed_body["error"]
      end
    end
  end
end
