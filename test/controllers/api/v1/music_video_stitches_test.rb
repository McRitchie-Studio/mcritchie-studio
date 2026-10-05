require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

module Api
  module V1
    # [integration] The final stitch as bin/stitch-video drives it: read the
    # requests, open one, report it started, finished or failed. The API serves
    # each stitch as the stitcher's request, takes resolved to their objects.
    class MusicVideoStitchesTest < ActionDispatch::IntegrationTest
      setup do
        @video = TiledVideo.seed!
        @base = "/api/v1/music_videos/#{@video.slug}/stitches"
      end

      def auth_headers
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}" }
      end

      def take_all! = @video.video_chunks.each { |chunk| TiledVideo.take!(chunk, number: 1, at: 1.hour.ago) }

      def api_post(path = "", params = {}) = post("#{@base}#{path}", params:, headers: auth_headers, as: :json)

      def body = JSON.parse(response.body)

      REPORT = { duration_ms: 72_000, byte_size: 3_500_000, width: 320, height: 180, frame_rate: "12", warnings: ["one note"] }.freeze

      test "every route needs the token" do
        get @base
        assert_response :unauthorized
        post @base, as: :json
        assert_response :unauthorized
        %w[start finish failed].each do |step|
          post "#{@base}/1/#{step}", as: :json
          assert_response :unauthorized
        end
      end

      test "the index says whether a stitch may be requested, and with which takes" do
        get @base, headers: auth_headers
        assert_response :ok
        assert_equal [[], false, "Chunk 1, Chunk 2, Chunk 3, and Chunk 4 have no generated take", []],
                     body["data"].values_at("stitches", "ready", "blocker", "current_takes")

        take_all!
        get @base, headers: auth_headers
        assert_equal [true, nil], body["data"].values_at("ready", "blocker")
        assert_equal [[1, 0, 25_000, 1], [2, 20_000, 45_000, 1], [3, 40_000, 65_000, 1], [4, 60_000, 72_000, 1]],
                     body["data"]["current_takes"].map { |t| t.values_at("ordinal", "start_ms", "end_ms", "take") }
      end

      test "a request is refused with the blocker until the video is ready" do
        api_post
        assert_response :conflict
        assert_equal ["NOT_READY", "Chunk 1, Chunk 2, Chunk 3, and Chunk 4 have no generated take"], body.values_at("error_code", "error")
        assert_equal 0, VideoStitch.count
      end

      test "a request is opened once and served as the stitcher's request" do
        take_all!
        api_post
        assert_response :created
        data = body["data"]
        assert_equal [1, "requested", "music_videos/test_artist_a/tiled_demo/stitched/tiled_demo_stitched_01.mp4", TiledVideo::SOURCE, 72_000],
                     data.values_at("number", "state", "object_key", "source_object_key", "source_duration_ms")
        assert_equal "music_videos/test_artist_a/tiled_demo/generated/tiled_demo_chunk_02_0020_0045_take_01.mp4",
                     data["takes"].second["object_key"]

        api_post
        assert_response :ok
        assert_equal 1, body["data"]["number"]
        assert_equal 1, @video.stitches.count

        get @base, headers: auth_headers
        assert_equal [[1, "requested"]], body["data"]["stitches"].map { |s| s.values_at("number", "state") }
      end

      test "start, then finish with the measurements" do
        take_all!
        api_post
        api_post("/1/start")
        assert_response :ok
        assert_equal "running", body["data"]["state"]
        assert_not_nil body["data"]["started_at"]

        api_post("/1/finish", REPORT)
        assert_response :ok
        assert_equal ["done", 72_000, 3_500_000, 320, 180, "12", ["one note"]],
                     body["data"].values_at("state", "duration_ms", "byte_size", "width", "height", "frame_rate", "warnings")
        assert_predicate @video.stitches.sole, :done?
      end

      test "a step out of order is a conflict that changes and logs nothing" do
        take_all!
        api_post
        assert_no_difference -> { ErrorLog.count } do
          api_post("/1/finish", REPORT)
          assert_response :conflict
          assert_equal ["WRONG_STATE", "Stitch 1 is requested, not running"], body.values_at("error_code", "error")

          api_post("/1/start")
          api_post("/1/start")
          assert_response :conflict
          assert_equal "Stitch 1 is running, not requested", body["error"]
        end
        assert_predicate @video.stitches.sole, :running?

        api_post("/1/start", { force: true })
        assert_response :ok
        api_post("/1/finish", REPORT)
        api_post("/1/failed", { reason: "too late" })
        assert_response :conflict
        assert_predicate @video.stitches.sole, :done?
      end

      test "a finish without its length and size is refused and the stitch keeps running" do
        take_all!
        api_post
        api_post("/1/start")
        [REPORT.except(:byte_size), REPORT.merge(duration_ms: 0), REPORT.merge(byte_size: "big")].each do |report|
          api_post("/1/finish", report)
          assert_response :unprocessable_entity
          assert_equal "INVALID_REPORT", body["error_code"]
        end
        assert_predicate @video.stitches.sole, :running?
      end

      test "a failure carries its reason" do
        take_all!
        api_post
        api_post("/1/start")
        api_post("/1/failed", { reason: "ffmpeg failed: Error: boom" })
        assert_response :ok
        assert_equal ["failed", "ffmpeg failed: Error: boom"], body["data"].values_at("state", "failure_reason")
      end

      test "an unknown video or stitch is not found" do
        get "/api/v1/music_videos/no-such-video/stitches", headers: auth_headers
        assert_response :not_found
        api_post("/9/start")
        assert_response :not_found
      end
    end
  end
end
