require "test_helper"

module Api
  module V1
    # [integration] GET /api/v1/dream_approvals — the pending approvals bin/dream
    # apply-approvals writes into the files. Bearer-gated and read-only. The one API
    # route that creates an approval is POST /api/v1/dream_rulings, and only on
    # Alex McRitchie's quoted word (dream_rulings_controller_test.rb).
    class DreamApprovalsControllerTest < ActionDispatch::IntegrationTest
      BANK = Rails.root.join("test/fixtures/dreams").to_s

      setup do
        @previous_bank = ENV["DREAM_BANK_DIR"]
        ENV["DREAM_BANK_DIR"] = BANK
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}"
        }
      end

      teardown { ENV["DREAM_BANK_DIR"] = @previous_bank }

      def approval(home, slug)
        DreamApproval.create!(dream_home: home, dream_slug: slug, approved_at: 1.hour.ago)
      end

      test "[integration] lists pending approvals with the deployed file's status" do
        approval("pokemon", "proposed-money-idea")
        approval("pokemon", "dropped-dream")

        get api_v1_dream_approvals_path, headers: @headers

        assert_response :ok
        body = response.parsed_body
        assert_equal 2, body.dig("meta", "count")
        rows = body["data"].index_by { |row| row["dream_slug"] }
        assert_equal "proposed", rows.dig("proposed-money-idea", "file_status")
        assert_equal "pokemon/proposed-money-idea.md", rows.dig("proposed-money-idea", "path")
        assert_equal "missing", rows.dig("dropped-dream", "file_status")
      end

      test "[integration] a row whose file already reads approved is stamped applied and drops out" do
        shipped = approval("carl", "money-review-reads-the-ledger")

        get api_v1_dream_approvals_path, headers: @headers

        assert_equal 0, response.parsed_body.dig("meta", "count")
        assert_not_nil shipped.reload.applied_at
      end

      test "[integration] the read needs a bearer, and only the chat-ruling route creates an approval" do
        get api_v1_dream_approvals_path
        assert_response :unauthorized

        post "/api/v1/dream_approvals", params: { dream_home: "pokemon", dream_slug: "proposed-money-idea" },
                                        headers: @headers
        assert_response :not_found
        assert_equal 0, DreamApproval.count
        refute Rails.application.routes.routes.any? { |route|
          route.path.spec.to_s.start_with?("/api/") && route.defaults[:controller].to_s.include?("dream_approval") &&
            route.verb != "GET"
        }, "every API route to dream approvals is a read"
        writers = Rails.application.routes.routes.select do |route|
          route.path.spec.to_s.start_with?("/api/") && route.verb != "GET" &&
            %w[dream_approval dream_retirement dream_ruling].any? { |name| route.defaults[:controller].to_s.include?(name) }
        end
        assert_equal [ "api/v1/dream_rulings#create" ],
                     writers.map { |route| "#{route.defaults[:controller]}##{route.defaults[:action]}" },
                     "the only API write that approves or retires is the chat ruling, which needs Alex McRitchie's words"
      end
    end
  end
end
