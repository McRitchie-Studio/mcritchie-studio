require "test_helper"
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

module Api
  module V1
    # [integration] A chunk's lettered reference frames as bin/clip-references
    # --apply posts them: the set replaces the chunk's frames, refills its
    # prompt, survives a re-tile at the same window, and anything the hub does
    # not know (a key, a letter, a time outside the chunk, a key outside its
    # refs folder) is refused whole. Behind the agent token. Synthetic people.
    class MusicVideoChunkReferencesTest < ActionDispatch::IntegrationTest
      setup do
        @video = LetteredVideo.seed!
        @chunk = @video.video_chunks.find_by!(ordinal: 2)
        @path = "/api/v1/music_videos/#{@video.slug}/chunks/2/references"
      end

      def auth_headers
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}" }
      end

      def key(number) = MusicVideos::ObjectKeys.chunk_reference(source_key: @video.source_object_key, ordinal: 2,
                                                                 start_ms: 20_000, end_ms: 45_000, number:)

      def frames = [{ object_key: key(1), t_ms: 42_000, letters: %w[A B] }, { object_key: key(2), t_ms: 30_000, letters: %w[A] }]

      def api_post(body) = post(@path, params: body, headers: auth_headers, as: :json)

      def body = JSON.parse(response.body)

      test "needs the token" do
        post @path, params: { frames: }, as: :json
        assert_response :unauthorized
        assert_empty @chunk.reload.reference_frames
      end

      test "the frames replace the chunk's set and its prompt now points at them" do
        assert_not_includes @chunk.prompt, "reference frames"

        api_post(frames:)

        assert_response :created
        assert_equal "music_videos/test_artist_b/lettered_demo/chunks/refs/lettered_demo_chunk_02_0020_0045_ref_01.jpg", key(1)
        assert_equal [[key(1), 42_000, %w[A B]], [key(2), 30_000, %w[A]]],
                     @chunk.reload.reference_frames.map { |f| f.values_at("object_key", "t_ms", "letters") }
        assert_equal 2, body.dig("data", "reference_frames").size
        assert_includes @chunk.prompt, "People are marked A, B, C... in the reference frames."

        api_post(frames: frames.first(1))
        assert_equal 1, @chunk.reload.reference_frames.size, "a post replaces the set whole"
      end

      test "unknown keys, letters, times and object keys are refused and change nothing" do
        refusals = [
          [{ frames:, names: { "B" => "Somebody" } }, "UNPERMITTED_KEYS"],
          [{ frames: [frames.first.merge(person: "Somebody")] }, "UNPERMITTED_KEYS"],
          [{ frames: [] }, "INVALID_FRAMES"],
          [{ frames: [frames.first.merge(letters: %w[A Q])] }, "INVALID_FRAMES"],
          [{ frames: [frames.first.merge(t_ms: 50_000)] }, "INVALID_FRAMES"],
          [{ frames: [frames.first.merge(object_key: "music_videos/elsewhere/x.jpg")] }, "INVALID_FRAMES"],
          [{ frames: [frames.second] }, "INVALID_FRAMES"] # numbered from 1: the first frame's key is ref_01
        ]
        refusals.each do |payload, code|
          api_post(payload)
          assert_response :unprocessable_entity, payload.inspect
          assert_equal code, body["error_code"], payload.inspect
        end
        assert_empty @chunk.reload.reference_frames
        assert_equal 0, ErrorLog.count, "a refusal is an answer, not an ErrorLog"
      end

      test "an unknown chunk is a 404" do
        post "/api/v1/music_videos/#{@video.slug}/chunks/9/references", params: { frames: }, headers: auth_headers, as: :json
        assert_response :not_found
      end

      test "a re-tile at the same windows keeps the frames; the API serves them with the chunks" do
        api_post(frames:)
        MusicVideos::ReplaceClips.new(@video.reload, LetteredVideo.chunk_rows(@video), kind: "chunk").call

        assert_equal 2, @video.video_chunks.find_by!(ordinal: 2).reference_frames.size
        get "/api/v1/music_videos/#{@video.slug}", headers: auth_headers
        assert_equal 2, body.dig("data", "chunks").find { |c| c["ordinal"] == 2 }["reference_frames"].size
        assert_equal [1], body.dig("data", "alt_videos").map { |a| a["number"] }
        assert_equal [2, 3], body.dig("data", "alt_videos", 0, "swaps").map { |s| s["performer_ordinal"] }
      end
    end
  end
end
