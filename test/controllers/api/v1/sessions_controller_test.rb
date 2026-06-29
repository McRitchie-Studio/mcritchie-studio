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

      test "POST mascot also returns the default app so a fresh session shows it" do
        post "/api/v1/sessions/sess-1/mascot", headers: @headers

        data = JSON.parse(response.body)["data"]
        assert_equal "mcritchie-studio", data["app"], "a brand-new session defaults to McRitchie Studio"
        assert_equal "#B57EDC", data["app_color"], "with its lavender status-line tint"
      end

      test "POST mascot is idempotent for a session" do
        post "/api/v1/sessions/sess-1/mascot", headers: @headers
        first = JSON.parse(response.body)["data"]["mascot"]
        post "/api/v1/sessions/sess-1/mascot", headers: @headers
        assert_equal first, JSON.parse(response.body)["data"]["mascot"]
        assert_equal 1, SessionMascot.where(session_id: "sess-1").count
      end

      test "POST mascot can draw a subagent from the parent evolution tree" do
        create_bellsprout_tree!
        SessionMascot.create!(session_id: "parent-sess", mascot_slug: "victreebel")
        SessionMascot.create!(session_id: "sibling-sess", parent_session_id: "parent-sess",
                              mascot_slug: "bellsprout")

        post "/api/v1/sessions/child-sess/mascot",
             params: { parent_session_id: "parent-sess" },
             headers: @headers,
             as: :json

        assert_response :success
        data = JSON.parse(response.body)["data"]
        assert_equal "weepinbell", data["mascot"]

        child = SessionMascot.find_by!(session_id: "child-sess")
        assert_equal "parent-sess", child.parent_session_id
      end

      test "POST mascot requires auth" do
        post "/api/v1/sessions/sess-1/mascot"
        assert_response :unauthorized
      end

      private

      def create_bellsprout_tree!
        [
          [69, "Bellsprout", "bellsprout"],
          [70, "Weepinbell", "weepinbell"],
          [71, "Victreebel", "victreebel"]
        ].each do |dex, name, slug|
          Pokemon.find_or_create_by!(slug: slug) do |pokemon|
            pokemon.dex = dex
            pokemon.name = name
            pokemon.types = %w[grass poison]
            pokemon.generation = 1
          end
        end
      end
    end
  end
end
