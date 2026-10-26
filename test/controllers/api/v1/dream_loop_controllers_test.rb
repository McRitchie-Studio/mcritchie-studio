require "test_helper"

module Api
  module V1
    # [integration] The dream loop's agent API (docs/agents/modules/dream.md, Act 4):
    # POST dream_grades and dream_swaps, GET dream_swaps/candidates and
    # dream_retirements. Bearer-gated; none of them approves or retires (that is
    # POST dream_rulings, on Alex McRitchie's quoted word only).
    class DreamLoopControllersTest < ActionDispatch::IntegrationTest
      BANK = Rails.root.join("test/fixtures/dreams").to_s

      setup do
        @previous_bank = ENV["DREAM_BANK_DIR"]
        ENV["DREAM_BANK_DIR"] = BANK
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}"
        }
      end

      teardown { ENV["DREAM_BANK_DIR"] = @previous_bank }

      def fire(slug, session:)
        AgentAction.create!(session_id: session, kind: DreamHeat::KIND, event_slug: slug, summary: "d",
                            occurred_at: 1.hour.ago, outcome: "ok")
      end

      def grade(params) = post(api_v1_dream_grades_path, params: params, headers: @headers, as: :json)

      test "[integration] a grade for a dream that fired in the session is recorded" do
        fire("list-the-candidates", session: "wrap")

        grade(session_id: "wrap", dream_slug: "list-the-candidates", score: 2, decision: "Listed both first")

        assert_response :created
        assert_equal 2, response.parsed_body.dig("data", "score")
        assert_equal 1, DreamGrade.count
      end

      test "[integration] a grade for a dream that did not fire in the session is refused" do
        fire("list-the-candidates", session: "another")

        grade(session_id: "wrap", dream_slug: "list-the-candidates", score: 1, decision: "x")

        assert_response :unprocessable_entity
        assert_equal "NOT_GRADABLE", response.parsed_body["error_code"]
        assert_match(/did not fire in this session/, response.parsed_body["error"])
        assert_equal 0, DreamGrade.count
      end

      test "[integration] a swap proposal and a no-swap answer are recorded once per session" do
        post api_v1_dream_swaps_path, params: { session_id: "wrap", in: "carl/new-habit", layer: "soul/carl",
                                                reason: "Captured a habit" }, headers: @headers, as: :json
        assert_response :created
        assert_equal "add", response.parsed_body.dig("data", "kind")

        post api_v1_dream_swaps_path, params: { session_id: "wrap", reason: "again" }, headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_equal "NOT_PROPOSABLE", response.parsed_body["error_code"]

        post api_v1_dream_swaps_path, params: { session_id: "quiet", reason: "Nothing earned a place" }, headers: @headers,
                                      as: :json
        assert_equal "none", response.parsed_body.dig("data", "kind")
        assert_equal 2, DreamSwap.count
      end

      test "[integration] candidates report each layer's room and ranked outs" do
        get api_v1_dream_swap_candidates_path, headers: @headers

        assert_response :ok
        layers = response.parsed_body["data"].index_by { |row| row["layer"] }
        assert_equal 15, layers.dig("platform", "budget")
        assert_equal 20, layers.dig("soul/pokemon", "budget")
        assert layers.dig("soul/pokemon", "candidates").any?

        get api_v1_dream_swap_candidates_path(layer: "soul/carl"), headers: @headers
        assert_equal [ "soul/carl" ], response.parsed_body["data"].map { |row| row["layer"] }

        get api_v1_dream_swap_candidates_path(layer: "galaxy"), headers: @headers
        assert_response :not_found
      end

      test "[integration] retirements lists pending rows and reconciles a deleted file" do
        DreamRetirement.create!(dream_home: "carl", dream_slug: "money-review-reads-the-ledger", retired_at: 1.hour.ago)
        gone = DreamRetirement.create!(dream_home: "carl", dream_slug: "already-deleted", retired_at: 1.hour.ago)

        get api_v1_dream_retirements_path, headers: @headers

        assert_response :ok
        assert_equal [ "money-review-reads-the-ledger" ], response.parsed_body["data"].map { |row| row["dream_slug"] }
        assert_equal "approved", response.parsed_body.dig("data", 0, "file_status")
        assert_not_nil gone.reload.applied_at
      end

      test "[integration] every loop route needs a bearer, and only the chat ruling retires or approves" do
        post api_v1_dream_grades_path, params: { session_id: "wrap", dream_slug: "x", score: 1, decision: "x" }, as: :json
        assert_response :unauthorized
        post api_v1_dream_swaps_path, params: { session_id: "wrap", reason: "x" }, as: :json
        assert_response :unauthorized
        get api_v1_dream_retirements_path
        assert_response :unauthorized

        routes = Rails.application.routes.routes.map { |route| [ route.verb, route.path.spec.to_s ] }
        api = routes.select { |_, path| path.start_with?("/api/v1/dream") }
        assert_equal [ [ "POST", "/api/v1/dream_grades(.:format)" ], [ "POST", "/api/v1/dream_rulings(.:format)" ],
                       [ "POST", "/api/v1/dream_swaps(.:format)" ] ],
                     api.select { |verb, _| verb != "GET" }.sort
      end
    end
  end
end
