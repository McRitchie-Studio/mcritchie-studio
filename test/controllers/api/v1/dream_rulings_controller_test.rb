require "test_helper"

module Api
  module V1
    # [integration] POST /api/v1/dream_rulings — Alex McRitchie's ruling given in chat, recorded
    # by the session that heard it with his verbatim words (bin/dream approve|drop|
    # retire --clearance). The one API route that approves or retires, and only on
    # his quoted word; apply-approvals then reads the rows like his clicks.
    class DreamRulingsControllerTest < ActionDispatch::IntegrationTest
      BANK = Rails.root.join("test/fixtures/dreams").to_s
      PROPOSED = { dream_home: "pokemon", dream_slug: "proposed-money-idea" }.freeze
      APPROVED = { dream_home: "carl", dream_slug: "money-review-reads-the-ledger" }.freeze

      setup do
        @previous_bank = ENV["DREAM_BANK_DIR"]
        ENV["DREAM_BANK_DIR"] = BANK
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}"
        }
      end

      teardown { ENV["DREAM_BANK_DIR"] = @previous_bank }

      def rule(ruling, target, clearance: "Approve it, refunds go through the ledger", session: "chat-1", headers: @headers)
        post api_v1_dream_rulings_path, params: target.merge(ruling: ruling, clearance: clearance, session_id: session),
                                        headers: headers, as: :json
      end

      test "[integration] approve stores the verbatim quote and the session, and the approvals read serves it" do
        rule("approve", PROPOSED)

        assert_response :created
        data = response.parsed_body["data"]
        assert_equal [ "approve", "chat", "Approve it, refunds go through the ledger", "chat-1", users(:alex).slug ],
                     data.values_at("ruling", "via", "clearance", "session_id", "approved_by")
        row = DreamApproval.sole
        assert_equal [ "chat", "chat-1" ], [ row.via, row.session_id ]

        get api_v1_dream_approvals_path, headers: @headers
        assert_equal "Approve it, refunds go through the ledger", response.parsed_body["data"].sole["clearance"]
      end

      test "[integration] drop of a proposed dream is a retirement apply-approvals deletes" do
        rule("drop", PROPOSED, clearance: "drop that one, it is a fact")

        assert_response :created
        assert_equal "drop", DreamRetirement.sole.ruling
        get api_v1_dream_retirements_path, headers: @headers
        row = response.parsed_body["data"].sole
        assert_equal [ "drop", "pokemon/proposed-money-idea.md", "drop that one, it is a fact" ],
                     row.values_at("ruling", "path", "clearance")
      end

      test "[integration] retire takes an approved dream" do
        rule("retire", APPROVED, clearance: "retire the ledger one")

        assert_response :created
        assert_equal [ "retire", "chat" ], DreamRetirement.sole.then { |row| [ row.ruling, row.via ] }
      end

      test "[integration] a token or slug clearance, a missing session, a wrong status or an unknown dream is 422" do
        rule("approve", PROPOSED, clearance: "ok")
        assert_response :unprocessable_entity
        assert_includes response.parsed_body["error"], "shorter than 3 words"

        rule("approve", PROPOSED, clearance: "proposed-money-idea")
        assert_includes response.parsed_body["error"], "only the slug"

        rule("approve", PROPOSED, session: "")
        assert_includes response.parsed_body["error"], "session"

        rule("approve", APPROVED)
        assert_includes response.parsed_body["error"], "not proposed"

        rule("approve", { dream_home: "pokemon", dream_slug: "nowhere" })
        assert_includes response.parsed_body["error"], "deployed bank"
        assert_equal 0, DreamApproval.count + DreamRetirement.count
      end

      test "[integration] a second ruling answers 200 with the first row" do
        rule("approve", PROPOSED)
        rule("approve", PROPOSED, clearance: "yes approve again please")

        assert_response :ok
        assert_equal "Approve it, refunds go through the ledger", response.parsed_body.dig("data", "clearance")
        assert_equal 1, DreamApproval.count
      end

      test "[integration] the ruling needs a bearer" do
        rule("approve", PROPOSED, headers: {})

        assert_response :unauthorized
        assert_equal 0, DreamApproval.count
      end
    end
  end
end
