require "test_helper"

module Api
  module V1
    class AgentsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      test "show includes status-line persona fields" do
        Agent.create!(name: "Jasper", slug: "jasper", status: "active",
                      metadata: { "emoji" => "🧪", "color" => "#22D3EE" })

        get api_v1_agent_path("jasper"), headers: @headers

        assert_response :success
        data = JSON.parse(response.body).fetch("data")
        assert_equal "Jasper", data["name"]
        assert_equal "🧪", data["emoji"]
        assert_equal "#22D3EE", data["status_color"]
      end
    end
  end
end
