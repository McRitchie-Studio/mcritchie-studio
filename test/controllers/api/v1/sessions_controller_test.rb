require "test_helper"

module Api
  module V1
    class SessionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
        # A single gen-1 Pokémon so the draw is deterministic, with its type color + emoji.
        Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1)
        Studio::Enumeral.create!(category: "pokemon_type", key: "normal",
                                 color: "#A8A77A", metadata: { "emoji" => "🔶" })
      end

      test "POST mascot draws + returns the session's mascot with color and emoji" do
        post "/api/v1/sessions/sess-1/mascot", headers: @headers

        assert_response :success
        data = JSON.parse(response.body)["data"]
        assert_equal "snorlax", data["mascot"]
        assert_equal "#A8A77A", data["mascot_color"]
        assert_equal "🔶", data["mascot_emoji"]
      end

      test "POST mascot is idempotent for a session" do
        post "/api/v1/sessions/sess-1/mascot", headers: @headers
        first = JSON.parse(response.body)["data"]["mascot"]
        post "/api/v1/sessions/sess-1/mascot", headers: @headers
        assert_equal first, JSON.parse(response.body)["data"]["mascot"]
        assert_equal 1, SessionMascot.where(session_id: "sess-1").count
      end

      test "POST mascot requires auth" do
        post "/api/v1/sessions/sess-1/mascot"
        assert_response :unauthorized
      end
    end
  end
end
