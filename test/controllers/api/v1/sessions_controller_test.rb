require "test_helper"

module Api
  module V1
    class SessionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}"
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

      test "POST mascot marks shiny draws with sparkle after type emoji" do
        Pokemon.stub(:roll_shiny?, true) do
          post "/api/v1/sessions/sess-shiny/mascot", headers: @headers
        end

        assert_response :success
        data = JSON.parse(response.body)["data"]
        assert_equal true, data["mascot_shiny"]
        assert_equal "🔶✨", data["mascot_emoji"]
      end

      # tasks/pokemon-mascot-gender: bin/task writes this into the session marker,
      # and bin/statusline names a gender family's form by it.
      test "POST mascot returns the session's gender roll" do
        Pokemon.find_by!(slug: "snorlax").update!(gender_rate: 1)
        Pokemon.stub(:gender_die, 0) do
          post "/api/v1/sessions/sess-gender/mascot", headers: @headers
        end

        assert_response :success
        assert_equal "female", JSON.parse(response.body).dig("data", "mascot_gender")
      end

      # tasks/show-mascot-gender-symbol: a genderless species is told apart from a
      # pre-gender draw, so bin/statusline can show Magnemite⚥ yet a legacy draw bare.
      test "POST mascot returns genderless for a gender_rate -1 species" do
        Pokemon.find_by!(slug: "snorlax").update!(gender_rate: -1)
        post "/api/v1/sessions/sess-genderless/mascot", headers: @headers

        assert_response :success
        assert_equal "genderless", JSON.parse(response.body).dig("data", "mascot_gender")
      end

      test "POST mascot returns no gender for a pre-gender draw of a gendered species" do
        Pokemon.find_by!(slug: "snorlax").update!(gender_rate: 1)
        SessionMascot.create!(session_id: "sess-legacy", mascot_slug: "snorlax", gender: nil)
        post "/api/v1/sessions/sess-legacy/mascot", headers: @headers

        assert_response :success
        assert_nil JSON.parse(response.body).dig("data", "mascot_gender")
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
          [69, "Bellsprout", "bellsprout", ["weepinbell"]],
          [70, "Weepinbell", "weepinbell", ["victreebel"]],
          [71, "Victreebel", "victreebel", []]
        ].each do |dex, name, slug, evolution|
          Pokemon.find_or_create_by!(slug: slug) do |pokemon|
            pokemon.dex = dex
            pokemon.name = name
            pokemon.types = %w[grass poison]
            pokemon.generation = 1
            pokemon.base = "bellsprout" # families derive from the columns now
            pokemon.evolution = evolution
          end
        end
      end
    end
  end
end
