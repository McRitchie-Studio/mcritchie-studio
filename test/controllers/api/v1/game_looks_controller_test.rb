require "test_helper"

module Api
  module V1
    # [integration] POST /api/v1/game_looks as bin/game-model file posts it: the
    # sheet's R2 key arrives, the hub makes the player's look for that game, its
    # iced twin for an iced sheet, and files each sheet as that look's
    # character-sheet artifact. Re-posting returns what is on file. Behind the
    # agent token; unknown keys, a key outside the folder, an object not in the
    # bucket and an unknown athlete are refused whole.
    class GameLooksControllerTest < ActionDispatch::IntegrationTest
      BASE_KEY = "character-sheets/game-models/3918298/bills-white-2026-week-6-at-lv-base-20261018230000.jpg".freeze
      ICED_KEY = "character-sheets/game-models/3918298/bills-white-2026-week-6-at-lv-iced-20261018230000.jpg".freeze
      DESCRIPTOR = "Bills white · 2026 Week 6 at LV".freeze

      setup do
        athletes(:allen_athlete).update!(espn_id: "3918298")
        @stored = [BASE_KEY, ICED_KEY]
      end

      def auth_headers
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}" }
      end

      def payload(sheets = [{ variant: "base", object_key: BASE_KEY }, { variant: "iced", object_key: ICED_KEY }])
        { espn_id: "3918298", descriptor: DESCRIPTOR, jersey_number: 17, sheets: sheets }
      end

      def api_post(body)
        Studio::S3.stub(:exists?, ->(key:) { @stored.include?(key) }) do
          Studio::S3.stub(:url, ->(key:) { "https://files.example.test/#{key}" }) do
            post "/api/v1/game_looks", params: body, headers: auth_headers, as: :json
          end
        end
      end

      def data = JSON.parse(response.body)["data"]

      test "needs the token" do
        post "/api/v1/game_looks", params: payload, as: :json
        assert_response :unauthorized
      end

      test "files the base sheet on the game look and the iced sheet on its twin" do
        assert_difference -> { Artifact.count } => 2, -> { Appearance.count } => 2 do
          api_post(payload)
        end
        assert_response :created

        look = Appearance.find_by!(slug: data["look"])
        twin = Appearance.find_by!(slug: data["iced_twin"])
        assert_equal ["josh-allen", DESCRIPTOR, 17, false], [look.person_slug, look.descriptor, look.jersey_number, look.iced]
        assert_equal [true, look.slug], [twin.iced, twin.base_appearance_slug]

        base, iced = data["artifacts"]
        assert_equal ["https://files.example.test/#{BASE_KEY}", look.slug], [base["url"], base["look"]]
        assert_equal ["https://files.example.test/#{ICED_KEY}", twin.slug], [iced["url"], iced["look"]]
        artifact = Artifact.find_by!(slug: base["slug"])
        assert_equal ["character_sheet", "game_model_layered", "gpt-image-2.5-sunburst-2026-09-08"],
                     [artifact.kind, artifact.generator, artifact.generator_version]
      end

      test "a re-post returns what is on file" do
        api_post(payload)
        first = data

        assert_no_difference -> { Artifact.count } do
          assert_no_difference -> { Appearance.count } do
            api_post(payload)
          end
        end
        assert_response :ok
        assert_equal first, data
      end

      test "a look that may not have an iced twin refuses the iced sheet, 422, and files nothing" do
        look = Appearance.create!(person_slug: "josh-allen", descriptor: DESCRIPTOR)
        look.update_column(:team_slug, "no-such-team") # a dangling team, as old rows carry

        assert_no_difference ["Artifact.count", "Appearance.count", "ErrorLog.count"] do
          api_post(payload)
        end
        assert_response :unprocessable_entity
        assert_equal "NO_ICED_TWIN", JSON.parse(response.body)["error_code"]
      end

      test "a base sheet alone makes no twin" do
        api_post(payload([{ variant: "base", object_key: BASE_KEY }]))

        assert_response :created
        assert_nil data["iced_twin"]
        assert_nil Appearance.find_by!(slug: data["look"]).iced_twin
      end

      test "refusals write nothing" do
        cases = {
          payload.merge(extra: 1) => [:unprocessable_entity, "UNPERMITTED_KEYS"],
          payload([{ variant: "base", object_key: "character-sheets/josh-allen/x.jpg" }]) => [:unprocessable_entity, "INVALID_KEY"],
          payload([{ variant: "gold", object_key: BASE_KEY }]) => [:unprocessable_entity, "INVALID"],
          payload([]) => [:unprocessable_entity, "INVALID"],
          payload.merge(espn_id: "1") => [:not_found, "NO_ATHLETE"]
        }
        cases.each do |body, (status, code)|
          assert_no_difference ["Artifact.count", "Appearance.count"] do
            api_post(body)
          end
          assert_response status
          assert_equal code, JSON.parse(response.body)["error_code"], body.inspect
        end

        @stored = []
        api_post(payload)
        assert_equal "OBJECT_MISSING", JSON.parse(response.body)["error_code"]
      end
    end
  end
end
