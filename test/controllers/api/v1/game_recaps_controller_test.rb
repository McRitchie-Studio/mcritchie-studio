require "test_helper"

module Api
  module V1
    class GameRecapsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @bills = teams(:buffalo_bills)
        @fins  = teams(:miami_dolphins)
      end

      def auth_headers
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}" }
      end

      def game(**overrides)
        {
          game_slug:      "buffalo-bills-vs-miami-dolphins",
          home_team_slug: @bills.slug,
          away_team_slug: @fins.slug,
          home_score:     24,
          away_score:     17,
          status_detail:  "Final",
          season_year:    2026,
          season_type:    2,
          week:           3
        }.merge(overrides)
      end

      def post_game(**overrides)
        post api_v1_game_recaps_path,
             params: { game: game(**overrides) },
             headers: auth_headers,
             as: :json
      end

      test "creates a recap idea from a finished game" do
        assert_difference -> { Content.count }, 1 do
          post_game
        end

        assert_response :created
        body = JSON.parse(response.body)["data"]
        assert_equal "Bills Beat Dolphins 24-17", body["title"]
        assert_equal "idea",       body["stage"]
        assert_equal "game_recap", body["workflow"]
        assert_equal "buffalo-bills-vs-miami-dolphins", body["game_slug"]
      end

      test "the created recap is findable by its returned slug" do
        post_game
        slug = JSON.parse(response.body)["data"]["slug"]

        assert Content.find_by(slug: slug).game_recap?
      end

      # The poll cycle re-runs by design, so this is the ordinary case.
      test "a repeated final answers 200 and creates nothing" do
        post_game
        assert_response :created

        assert_no_difference -> { Content.count } do
          post_game
        end

        assert_response :ok
      end

      test "rejects an unauthenticated caller" do
        assert_no_difference -> { Content.count } do
          post api_v1_game_recaps_path, params: { game: game }, as: :json
        end

        assert_response :unauthorized
        assert_equal "UNAUTHORIZED", JSON.parse(response.body)["error_code"]
      end

      test "rejects a bad token" do
        assert_no_difference -> { Content.count } do
          post api_v1_game_recaps_path,
               params: { game: game },
               headers: { "Authorization" => "Bearer not-a-real-token" },
               as: :json
        end

        assert_response :unauthorized
      end

      test "rejects a game naming a team the hub does not know" do
        assert_no_difference -> { Content.count } do
          post_game(away_team_slug: "nonexistent-team")
        end

        assert_response :unprocessable_entity
        assert_equal "INVALID_GAME", JSON.parse(response.body)["error_code"]
      end

      test "rejects a non-numeric score rather than inventing a shutout" do
        assert_no_difference -> { Content.count } do
          post_game(home_score: "final")
        end

        assert_response :unprocessable_entity
      end

      test "rejects a payload missing the game slug" do
        assert_no_difference -> { Content.count } do
          post_game(game_slug: nil)
        end

        assert_response :unprocessable_entity
      end

      test "a tie is recorded without naming a winner" do
        post_game(home_score: 20, away_score: 20)

        assert_response :created
        assert_equal "Bills And Dolphins Tie 20-20", JSON.parse(response.body)["data"]["title"]
      end
    end
  end
end
