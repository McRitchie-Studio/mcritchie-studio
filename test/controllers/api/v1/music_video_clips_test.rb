require "test_helper"
require Rails.root.join("db/seeds/data/night_call_clips.rb").to_s

module Api
  module V1
    # [integration] POST /api/v1/music_videos/:slug/clips — bin/find-clips
    # replaces the clip set; the hub fills the prompts; no clips before the cast.
    class MusicVideoClipsTest < ActionDispatch::IntegrationTest
      setup { @video = NightCallClips.video! }

      def auth_headers
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}" }
      end

      def post_clips(clips, video: @video, headers: auth_headers)
        post clips_api_v1_music_video_path(video), params: { clips: }, headers:, as: :json
      end

      def body = JSON.parse(response.body)

      test "replaces the set, fills each prompt, and reports approvals dropped" do
        post_clips(NightCallClips.rows)
        assert_response :ok
        @video.video_clips.first.update!(status: "approved")
        @video.sync_clip_stage!

        post_clips(NightCallClips.rows.first(1))
        assert_response :ok
        assert_equal 1, body.dig("meta", "dropped_approvals")
        clips = body.dig("data", "clips")
        assert_equal [[1, "proposed", "solo_plus_background", 1]], clips.map { |c| c.values_at("ordinal", "status", "cast_shape", "target_performer") }
        assert_match "Replace the person in the desk scenes in this music video with {athlete}", clips.first["prompt"]
        assert_equal "cast_confirmed", @video.reload.stage, "no approved clip is left"
      end

      test "refuses before the cast is confirmed, and writes nothing" do
        digested = NightCallCast.seed!

        post_clips(NightCallClips.rows, video: digested)
        assert_response :conflict
        assert_equal "CAST_NOT_CONFIRMED", body["error_code"]
        assert_match "neither an artist nor an extra", body["error"]
        assert_equal 0, digested.video_clips.count
      end

      test "the agent may not send the prompt or a status" do
        rows = NightCallClips.rows
        rows[0]["prompt"] = "anything"
        rows[1]["status"] = "approved"

        post_clips(rows)
        assert_response :unprocessable_entity
        assert_equal "UNPERMITTED_KEYS", body["error_code"]
        assert_match "prompt, status", body["error"]
      end

      test "an invalid row rolls the whole replace back" do
        post_clips(NightCallClips.rows)
        rows = NightCallClips.rows
        rows[1]["end_ms"] = rows[1]["start_ms"] + 40_000

        assert_no_changes -> { @video.video_clips.reload.pluck(:id) } do
          post_clips(rows)
        end
        assert_response :unprocessable_entity
      end

      test "an empty set and a missing token are refused" do
        post_clips([])
        assert_equal "INVALID_CLIPS", body["error_code"]
        post_clips(NightCallClips.rows, headers: {})
        assert_response :unauthorized
      end

      test "GET shows the clips alongside the performers" do
        post_clips(NightCallClips.rows)
        get api_v1_music_video_path(@video), headers: auth_headers
        assert_equal [1, 2], body.dig("data", "clips").map { |c| c["ordinal"] }
        assert_equal 7, body.dig("data", "performers").size
      end
    end
  end
end
