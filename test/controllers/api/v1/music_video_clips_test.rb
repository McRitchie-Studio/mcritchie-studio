require "test_helper"
require Rails.root.join("db/seeds/data/night_call_clips.rb").to_s
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

module Api
  module V1
    # [integration] POST /api/v1/music_videos/:slug/clips — bin/find-clips
    # replaces the clip set; the hub fills the prompts; no clips before the cast.
    # With kind "chunk" it replaces the tiling instead, and neither set touches the other.
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
        assert_equal "the cast is not confirmed yet: confirm it first", body["error"], "naming is optional: nothing blocks but the confirm itself"
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

      test "kind chunk replaces the chunks and keeps the candidates" do
        video = TiledVideo.seed!
        candidate = video.clip_candidates.sole
        candidate.update!(status: "approved")
        video.sync_clip_stage!
        old_chunk_ids = video.video_chunks.pluck(:id)

        post clips_api_v1_music_video_path(video), params: { kind: "chunk", clips: TiledVideo.chunk_rows(video) },
                                                   headers: auth_headers, as: :json
        assert_response :ok
        assert_equal 0, body.dig("meta", "dropped_approvals"), "the approved candidate was not in the replaced set"
        assert_equal [[1, 0, 25_000], [2, 20_000, 45_000], [3, 40_000, 65_000], [4, 60_000, 72_000]],
                     body.dig("data", "chunks").map { |c| c.values_at("ordinal", "start_ms", "end_ms") }
        assert_equal ["chunk"], body.dig("data", "chunks").map { |c| c["kind"] }.uniq
        assert_equal [nil], body.dig("data", "chunks").map { |c| c["seam"] }.uniq
        assert_match "Replace the man in the red jacket in this video with {athlete}", body.dig("data", "chunks", 0, "prompt")
        assert_no_match(/music video/, body.dig("data", "chunks", 0, "prompt"))
        assert_empty old_chunk_ids & video.video_chunks.reload.pluck(:id), "the old chunks were replaced"

        assert_equal [[candidate.id, "approved"]], video.clip_candidates.reload.pluck(:id, :status)
        assert_equal [["candidate", 1, "approved"]], body.dig("data", "clips").map { |c| c.values_at("kind", "ordinal", "status") }
        assert_equal "clips_ready", video.reload.stage
      end

      test "posting candidates replaces the candidates and keeps the chunks" do
        video = TiledVideo.seed!
        chunk_ids = video.video_chunks.pluck(:id)
        old_candidate = video.clip_candidates.sole.id

        post_clips(TiledVideo.candidate_rows, video:)
        assert_response :ok
        assert_equal chunk_ids, video.video_chunks.reload.pluck(:id)
        assert_not_equal old_candidate, video.clip_candidates.reload.sole.id
        assert_equal 4, body.dig("data", "chunks").size
      end

      test "a chunk row may not carry a seam, a prompt or a status" do
        video = TiledVideo.seed!
        rows = TiledVideo.chunk_rows(video)
        rows[0]["seam"] = "section_change"
        rows[1]["seam_ms"] = 30_000
        rows[2]["prompt"] = "anything"

        assert_no_changes -> { video.video_chunks.reload.pluck(:id) } do
          post clips_api_v1_music_video_path(video), params: { kind: "chunk", clips: rows }, headers: auth_headers, as: :json
        end
        assert_response :unprocessable_entity
        assert_equal "UNPERMITTED_KEYS", body["error_code"]
        assert_match "seam, seam_ms, prompt", body["error"]
      end

      test "a chunk set that is not the whole tiling is refused and writes nothing" do
        video = TiledVideo.seed!
        whole = TiledVideo.chunk_rows(video)
        shifted = TiledVideo.chunk_rows(video).tap { |rows| rows[1]["start_ms"] = 21_000 }
        gap = TiledVideo.chunk_rows(video).tap { |rows| rows.delete_at(1) }
        short_middle = TiledVideo.chunk_rows(video).tap { |rows| rows[1]["end_ms"] = 44_000 }
        seam_window = TiledVideo.candidate_rows.map { |row| row.except("seam", "seam_ms") }
        no_times = [whole.first.merge("end_ms" => "25000")]

        { whole.first(3) => "tile the whole video", shifted => "20000 ms stride", gap => "20000 ms stride",
          short_middle => "only the last one shorter", seam_window => "20000 ms stride", no_times => "20000 ms stride" }.each do |rows, why|
          assert_no_changes -> { video.video_chunks.reload.pluck(:id) } do
            post clips_api_v1_music_video_path(video), params: { kind: "chunk", clips: rows }, headers: auth_headers, as: :json
          end
          assert_response :unprocessable_entity
          assert_equal "INVALID_TILING", body["error_code"]
          assert_match why, body["error"]
        end
      end

      test "the last chunk may end up to a second short of the recorded duration, never past it" do
        video = TiledVideo.seed!
        post clips_api_v1_music_video_path(video), params: { kind: "chunk", clips: TiledVideo.chunk_rows(video, duration_ms: 71_200) },
                                                   headers: auth_headers, as: :json
        assert_response :ok
        assert_equal 71_200, video.video_chunks.reload.last.end_ms

        post clips_api_v1_music_video_path(video), params: { kind: "chunk", clips: TiledVideo.chunk_rows(video, duration_ms: 72_001) },
                                                   headers: auth_headers, as: :json
        assert_response :unprocessable_entity
        assert_equal "INVALID_TILING", body["error_code"]
        assert_equal 71_200, video.video_chunks.reload.last.end_ms
      end

      def post_chunks(video, rows, **tiling)
        post clips_api_v1_music_video_path(video), params: { kind: "chunk", clips: rows, **tiling }, headers: auth_headers, as: :json
      end

      test "a chunk post with no tiling records the default 25 s and 5 s on the video" do
        video = TiledVideo.video!
        assert_nil video.chunk_tiling

        post_chunks(video, TiledVideo.chunk_rows(video))
        assert_response :ok
        assert_equal [25_000, 5_000], body["data"].values_at("chunk_ms", "chunk_overlap_ms")
        assert_equal({ chunk_ms: 25_000, overlap_ms: 5_000 }, video.reload.chunk_tiling)
      end

      test "a 15 s chunk with a 5 s overlap replaces a 25 s tiling, and the video records it" do
        video = TiledVideo.seed!
        tiling = { chunk_ms: 15_000, overlap_ms: 5_000 }
        rows = TiledVideo.chunk_rows(video, **tiling)

        post_chunks(video, rows, chunk_ms: 15_000, chunk_overlap_ms: 5_000)
        assert_response :ok
        assert_equal [15_000, 5_000], body["data"].values_at("chunk_ms", "chunk_overlap_ms")
        assert_equal [[1, 0, 15_000], [2, 10_000, 25_000], [3, 20_000, 35_000], [4, 30_000, 45_000], [5, 40_000, 55_000],
                      [6, 50_000, 65_000], [7, 60_000, 72_000]],
                     body.dig("data", "chunks").map { |c| c.values_at("ordinal", "start_ms", "end_ms") }
        assert_equal "music_videos/test_artist_a/tiled_demo/chunks/tiled_demo_chunk_02_0010_0025.mp4", body.dig("data", "chunks", 1, "object_key")
        assert(video.video_chunks.reload.all?(&:valid?))
        assert_equal 1, video.clip_candidates.count
      end

      test "15 s rows sent without their tiling are measured against the default and refused" do
        video = TiledVideo.seed!
        assert_no_changes -> { [video.video_chunks.reload.pluck(:id), video.reload.chunk_tiling] } do
          post_chunks(video, TiledVideo.chunk_rows(video, chunk_ms: 15_000, overlap_ms: 5_000))
        end
        assert_response :unprocessable_entity
        assert_equal "INVALID_TILING", body["error_code"]
      end

      test "an overlap as long as the chunk, or a tiling that is not whole milliseconds, is refused" do
        video = TiledVideo.seed!
        rows = TiledVideo.chunk_rows(video)
        { { chunk_ms: 15_000, chunk_overlap_ms: 15_000 } => "must be shorter than the chunk",
          { chunk_ms: 5_000, chunk_overlap_ms: 9_000 } => "must be shorter than the chunk",
          { chunk_ms: 0, chunk_overlap_ms: 0 } => "chunk length",
          { chunk_ms: "15", chunk_overlap_ms: 5_000 } => "chunk length",
          { chunk_ms: 15_000, chunk_overlap_ms: -1 } => "overlap" }.each do |tiling, why|
          assert_no_changes -> { [video.video_chunks.reload.pluck(:id), video.reload.chunk_tiling] } do
            post_chunks(video, rows, **tiling)
          end
          assert_response :unprocessable_entity
          assert_equal "INVALID_TILING", body["error_code"]
          assert_match why, body["error"]
        end
      end

      test "a candidate post may not carry a tiling" do
        video = TiledVideo.seed!
        post clips_api_v1_music_video_path(video), params: { clips: TiledVideo.candidate_rows, chunk_ms: 15_000 }, headers: auth_headers, as: :json
        assert_response :unprocessable_entity
        assert_equal "UNPERMITTED_KEYS", body["error_code"]
        assert_equal({ chunk_ms: 25_000, overlap_ms: 5_000 }, video.reload.chunk_tiling)
      end

      test "an unknown kind is refused" do
        post clips_api_v1_music_video_path(@video), params: { kind: "tile", clips: NightCallClips.rows }, headers: auth_headers, as: :json
        assert_response :unprocessable_entity
        assert_equal "INVALID_KIND", body["error_code"]
        assert_equal 0, @video.video_clips.count
      end

      test "chunks wait for the cast like candidates do" do
        digested = NightCallCast.seed!
        rows = MusicVideos::ChunkTiler.windows(30_000).map do |w|
          { ordinal: w.ordinal, start_ms: w.start_ms, end_ms: w.end_ms, cast_shape: "unknown", performer_ordinals: [],
            object_key: MusicVideos::ObjectKeys.chunk(source_key: digested.source_object_key, **w.to_h) }
        end
        digested.update!(duration_ms: 30_000)

        post clips_api_v1_music_video_path(digested), params: { kind: "chunk", clips: rows }, headers: auth_headers, as: :json
        assert_response :conflict
        assert_equal "CAST_NOT_CONFIRMED", body["error_code"]
        assert_equal 0, digested.video_clips.count
      end

      test "GET shows the clips alongside the performers" do
        post_clips(NightCallClips.rows)
        get api_v1_music_video_path(@video), headers: auth_headers
        assert_equal [1, 2], body.dig("data", "clips").map { |c| c["ordinal"] }
        assert_equal [], body.dig("data", "chunks")
        assert_equal 7, body.dig("data", "performers").size
      end
    end
  end
end
