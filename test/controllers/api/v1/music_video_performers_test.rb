require "test_helper"
require Rails.root.join("db/seeds/data/night_call_cast.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

module Api
  module V1
    # [integration] POST /api/v1/music_videos/:slug/performers — the vision pass
    # replaces the performer set; artists stay the operator's call.
    class MusicVideoPerformersTest < ActionDispatch::IntegrationTest
      STILLS = "music_videos/steve_aoki/night_call/stills".freeze

      setup { @video = NightCallCast.seed! }

      def auth_headers
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}" }
      end

      def post_performers(performers, headers: auth_headers)
        post performers_api_v1_music_video_path(@video), params: { performers: }, headers:, as: :json
      end

      def two_people
        [{ ordinal: 1, label: "desk", still_object_keys: ["#{STILLS}/person_01_0230.jpg"],
           sightings: [{ t_ms: 150_000, visibility: "clear" }], confidence_note: "desk scenes" },
         { ordinal: 2, label: "armchair", still_object_keys: [], sightings: [] }]
      end

      def body = JSON.parse(response.body)

      test "replaces the whole set and reports the operator labels it dropped" do
        @video.video_performers.find_by!(ordinal: 3).update!(extra: true)

        assert_difference -> { @video.video_performers.count } => -5 do
          post_performers(two_people)
        end
        assert_response :ok
        assert_equal 1, body.dig("meta", "dropped_labels")
        assert_equal [[1, "desk", nil, false], [2, "armchair", nil, false]],
                     body.dig("data", "performers").map { |p| p.values_at("ordinal", "label", "artist_slug", "extra") }
        assert_equal [{ "t_ms" => 150_000, "visibility" => "clear" }], @video.video_performers.reload.first.sightings
        assert_equal ["#{STILLS}/person_01_0230.jpg"], @video.video_performers.first.still_object_keys
      end

      test "the agent may not set an artist, and nothing changes" do
        rows = two_people
        rows[0][:artist_slug] = "test-artist-a"

        assert_no_changes -> { @video.video_performers.pluck(:id) } do
          post_performers(rows)
        end
        assert_response :unprocessable_entity
        assert_equal "UNPERMITTED_KEYS", body["error_code"]
        assert_match "artist_slug", body["error"]
      end

      # The recast is the operator's choice, like the artist: the seam takes its
      # five fields and refuses the rest.
      test "the agent may not set a recast, by any of its keys, and nothing changes" do
        athlete = RecastVideo.athlete!
        { recast_person_slug: athlete.slug, recast_appearance_slug: athlete.appearances.first.slug,
          recast_keep: true, extra: true }.each do |key, value|
          rows = two_people
          rows[1][key] = value

          assert_no_changes -> { @video.video_performers.pluck(:id, :recast_person_slug, :recast_keep) } do
            post_performers(rows)
          end
          assert_response :unprocessable_entity
          assert_equal "UNPERMITTED_KEYS", body["error_code"]
          assert_match key.to_s, body["error"]
          assert_match "the operator sets artists and recasts", body["error"]
        end
        assert_equal %w[confidence_note label ordinal sightings still_object_keys], MusicVideos::ReplacePerformers::FIELDS.sort
      end

      test "a replace reports the recasts it dropped, apart from the labels" do
        athlete = RecastVideo.athlete!
        look = athlete.appearances.first
        @video.video_performers.find_by!(ordinal: 1).update!(recast_person_slug: athlete.slug, recast_appearance_slug: look.slug)
        @video.video_performers.find_by!(ordinal: 2).update!(recast_keep: true)
        @video.video_performers.find_by!(ordinal: 3).update!(extra: true)

        post_performers(two_people)

        assert_response :ok
        assert_equal({ "dropped_labels" => 1, "dropped_recasts" => 2 }, body["meta"].slice("dropped_labels", "dropped_recasts"))
        assert_equal [[nil, nil, false]] * 2,
                     @video.video_performers.reload.map { |p| p.values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep) }
        assert(body.dig("data", "performers").none? { |p| p.keys.any? { |k| k.start_with?("recast") } })
      end

      test "an invalid row rolls the whole replace back" do
        rows = two_people
        rows[1][:still_object_keys] = ["music_videos/drake/hotline_bling/stills/person_02_0100.jpg"]

        assert_no_changes -> { @video.video_performers.pluck(:id) } do
          post_performers(rows)
        end
        assert_response :unprocessable_entity
        assert_equal "VALIDATION_FAILED", body["error_code"]
      end

      test "a confirmed cast is never replaced" do
        @video.video_performers.update_all(extra: true)
        @video.confirm_cast!

        post_performers(two_people)
        assert_response :conflict
        assert_equal "CAST_CONFIRMED", body["error_code"]
        assert_equal 7, @video.video_performers.count
      end

      test "an empty list and a missing token are refused" do
        post_performers([])
        assert_response :unprocessable_entity

        post_performers(two_people, headers: {})
        assert_response :unauthorized
      end

      test "GET shows the performers" do
        get api_v1_music_video_path(@video), headers: auth_headers
        assert_equal (1..7).to_a, body.dig("data", "performers").map { |p| p["ordinal"] }
      end
    end
  end
end
