# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [integration] The recast round trip on /music_videos/:slug: the admin gate,
# uploading a generated MP4 as a numbered take (the file reaches the bucket
# seam, the chunk reads generated), putting an older take back, the regenerate
# flag, and the page's hand-off, flagged list and stitch preview.
class VideoChunkTakesControllerTest < ActionDispatch::IntegrationTest
  StoreTake = MusicVideos::StoreTake

  setup do
    @video = TiledVideo.seed!
    @stored = []
    stored = @stored
    @real_store = StoreTake.method(:store)
    StoreTake.define_singleton_method(:store) { |key:, body:| stored << [key, body.read.bytesize] }
  end

  teardown { StoreTake.define_singleton_method(:store, @real_store) }

  def mp4 = fixture_file_upload("stitch_demo.mp4", "video/mp4")

  def upload(ordinal, file = mp4) = post(music_video_chunk_takes_path(@video, ordinal), params: { file: })

  def chunk(ordinal) = @video.reload.video_chunks.find { |c| c.ordinal == ordinal }

  def timeline = JSON.parse(css_select("[data-test='stitch-preview']").sole["data-timeline"])

  test "non-admins can upload, pick or flag nothing" do
    TiledVideo.take!(chunk(2), number: 1)
    log_in_as users(:viewer)

    upload(2)
    assert_redirected_to root_path
    post current_music_video_chunk_take_path(@video, 2, 1)
    assert_redirected_to root_path
    post music_video_chunk_regenerate_path(@video, 2), params: { note: "no" }
    assert_redirected_to root_path
    delete music_video_chunk_regenerate_path(@video, 2)
    assert_redirected_to root_path

    assert_empty @stored
    assert_equal 1, VideoChunkTake.count
    assert_not chunk(2).regenerate_requested?
  end

  test "an upload stores the file as take 1 and the chunk reads generated" do
    log_in_as users(:alex)

    assert_difference -> { VideoChunkTake.count }, 1 do
      upload(2)
    end

    assert_redirected_to music_video_path(@video, anchor: "chunk-2")
    assert_equal "Chunk 2: take 1 uploaded and current.", flash[:notice]
    key = "music_videos/test_artist_a/tiled_demo/generated/tiled_demo_chunk_02_0020_0045_take_01.mp4"
    assert_equal [[key, file_fixture("stitch_demo.mp4").size]], @stored, "the whole file reached the bucket seam"
    assert_equal key, chunk(2).current_take.object_key
    assert_equal key, chunk(2).playback_object_key

    follow_redirect!
    assert_select "[data-test='chunk-row'][data-ordinal='2'][data-take='1']" do
      assert_select "[data-test='chunk-take-state']", "Take 1 current"
      assert_select "[data-test='chunk-take'][data-number='1'][data-current='true'][data-key=?]", key
      assert_select "[data-test='chunk-take-open'][href*='take_01.mp4'][href*='X-Amz-Signature']"
    end
    assert_select "[data-test='stitch-take-count']", "1 of 4"
    segment = timeline.fetch("segments").second
    assert_equal false, segment["source"]
    assert_equal "take 1", segment["label"]
    assert_match(/generated\/tiled_demo_chunk_02_0020_0045_take_01\.mp4\?.*X-Amz-Signature/, segment["url"])
  end

  test "a second upload is take 2, current, and take 1 is kept" do
    log_in_as users(:alex)
    upload(2)
    upload(2)

    assert_equal "Chunk 2: take 2 uploaded and current.", flash[:notice]
    assert_equal [1, 2], chunk(2).takes.map(&:number)
    assert_equal 2, @stored.map(&:first).uniq.size
    assert_equal 2, chunk(2).current_take.number
  end

  test "a refused file says why, stores nothing and logs no error" do
    log_in_as users(:alex)

    assert_no_difference [-> { VideoChunkTake.count }, -> { ErrorLog.count }] do
      upload(2, fixture_file_upload("notes.txt", "video/mp4"))
      assert_equal "Chunk 2 take not uploaded: that file is not an MP4.", flash[:alert]
      post music_video_chunk_takes_path(@video, 2)
      assert_equal "Chunk 2 take not uploaded: choose the generated MP4 first.", flash[:alert]
    end
    assert_redirected_to music_video_path(@video, anchor: "chunk-2")
    assert_empty @stored
  end

  test "a bucket failure tells the operator, records no take and logs the error" do
    log_in_as users(:alex)
    StoreTake.define_singleton_method(:store) { |**| raise StoreTake::StorageFailed, "object storage did not take it (AccessDenied)" }

    assert_difference -> { ErrorLog.count }, 1 do
      assert_no_difference -> { VideoChunkTake.count } do
        upload(2)
      end
    end
    assert_equal "Chunk 2 take not uploaded: object storage did not take it (AccessDenied). Nothing was recorded; try again.", flash[:alert]
  end

  test "a clip candidate and an unknown chunk are not reachable on the chunk routes" do
    log_in_as users(:alex)

    upload(9)
    assert_response :not_found
    post music_video_chunk_regenerate_path(@video, 9)
    assert_response :not_found
    assert_equal "proposed", @video.clip_candidates.sole.status
    assert_empty @stored
  end

  test "make current puts an older take back in front; an unknown take is a 404" do
    log_in_as users(:alex)
    TiledVideo.take!(chunk(2), number: 1, at: 2.minutes.ago)
    TiledVideo.take!(chunk(2), number: 2, at: 1.minute.ago)

    post current_music_video_chunk_take_path(@video, 2, 1)
    assert_redirected_to music_video_path(@video, anchor: "chunk-2")
    assert_equal "Chunk 2: take 1 is current.", flash[:notice]
    assert_equal 1, chunk(2).current_take.number

    post current_music_video_chunk_take_path(@video, 2, 7)
    assert_response :not_found
    post current_music_video_chunk_take_path(@video, 3, 1)
    assert_response :not_found, "take 1 belongs to chunk 2"
  end

  test "request regenerate flags the chunk with its note, and the page lists it" do
    log_in_as users(:alex)

    post music_video_chunk_regenerate_path(@video, 3), params: { note: "  the jersey   flickers " }
    assert_redirected_to music_video_path(@video, anchor: "chunk-3")
    assert_equal "Chunk 3 flagged for a regenerate.", flash[:notice]
    assert_equal "the jersey flickers", chunk(3).regenerate_note

    post music_video_chunk_regenerate_path(@video, 1)
    follow_redirect!
    assert_select "[data-test='chunks-flagged'][data-count='2'] [data-test='flagged-chunk']", 2
    assert_select "[data-test='flagged-chunk'][data-ordinal='3']", /Chunk 3\s+· 0:40–1:05\s+· the jersey flickers/ do
      assert_select "a[href='#chunk-3']", "Chunk 3"
    end
    assert_select "[data-test='chunk-row'][data-ordinal='3'][data-flagged='true'] [data-test='chunk-regenerate-note']", /the jersey flickers/
    assert_select "[data-test='chunk-row'][data-ordinal='2'][data-flagged='false'] [data-test='chunk-regenerate-form']", 1
    assert_equal [true, false, true, false], timeline.fetch("segments").pluck("flagged")
  end

  test "an over-long note is refused, and clearing removes the flag" do
    log_in_as users(:alex)

    post music_video_chunk_regenerate_path(@video, 3), params: { note: "x" * 281 }
    assert_equal "Chunk 3 not flagged: keep the note under 280 characters.", flash[:alert]
    assert_not chunk(3).regenerate_requested?

    chunk(3).request_regenerate!("hands")
    delete music_video_chunk_regenerate_path(@video, 3)
    assert_equal "Chunk 3: regenerate request cleared.", flash[:notice]
    assert_not chunk(3).regenerate_requested?
  end

  test "uploading a take clears that chunk's flag" do
    log_in_as users(:alex)
    chunk(2).request_regenerate!("again")

    upload(2)

    assert_not chunk(2).regenerate_requested?
    follow_redirect!
    assert_select "[data-test='chunks-flagged-none']", 1
  end

  test "the page is ready to stitch only when every chunk has a take and none is flagged" do
    log_in_as users(:alex)
    get music_video_path(@video)
    assert_select "[data-test='stitch-status'][data-ready='false'] [data-test='stitch-ready']", "Not ready to stitch"
    assert_select "[data-test='stitch-blocker']", /Chunk 1, Chunk 2, Chunk 3, and Chunk 4 have no generated take/
    assert_equal [true] * 4, timeline.fetch("segments").pluck("source"), "with no take every chunk plays its source"
    assert_equal %w[source] * 4, timeline.fetch("segments").pluck("label")

    (1..4).each { |ordinal| upload(ordinal) }
    get music_video_path(@video)
    assert_select "[data-test='stitch-status'][data-ready='true'] [data-test='stitch-ready']", "Ready to stitch"
    assert_select "[data-test='stitch-blocker']", 0
    assert @video.reload.ready_to_stitch?
  end

  test "the stitch preview carries the timeline, the source audio and a marker per chunk" do
    log_in_as users(:alex)
    TiledVideo.take!(chunk(3), number: 1)
    get music_video_path(@video)

    data = timeline
    assert_equal 72_000, data["duration_ms"]
    assert_equal [[1, 0, 22_500], [2, 22_500, 42_500], [3, 42_500, 62_500], [4, 62_500, 72_000]],
                 data["segments"].map { |s| s.values_at("ordinal", "from_ms", "to_ms") }
    assert_equal [0, 20_000, 40_000, 60_000], data["segments"].pluck("start_ms")
    assert_match(%r{chunks/tiled_demo_chunk_01_0000_0025\.mp4}, data["segments"].first["url"])
    assert_match(%r{generated/tiled_demo_chunk_03_0040_0105_take_01\.mp4}, data["segments"].third["url"])

    assert_select "[data-test='stitch-preview'][x-data='stitchPreview()']" do
      assert_select "video[data-test='stitch-video'][muted][preload='auto']", 2
      assert_select "audio[data-test='stitch-audio'][src*='source/test_artist_a_tiled_demo.mp4'][src*='X-Amz-Signature']", 1
      assert_select "[data-test='stitch-marker']", 4
      assert_select "[data-test='stitch-marker'][data-ordinal='3'][data-source='false'][data-from='42500'][data-to='62500']", /take 1/
      assert_select "[data-test='stitch-marker'][data-ordinal='2'][data-source='true']", /source/
      assert_select "input[data-test='stitch-seek'][max='72000']", 1
    end
  end

  test "a video with no chunks shows no stitch preview" do
    log_in_as users(:alex)
    @video.video_chunks.destroy_all
    get music_video_path(@video)

    assert_response :success
    assert_select "[data-test='stitch-preview']", 0
    assert_select "[data-test='chunks-empty']", 1
  end

  test "the page reads its takes in one query however many chunks have them" do
    log_in_as users(:alex)
    get music_video_path(@video) # warm
    count = lambda do
      queries = []
      # Cached reads count too: the query cache outlives a request here until a write.
      counter = ->(*, payload) { queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get music_video_path(@video) }
      assert_response :success
      queries.size
    end
    bare = count.call
    @video.video_chunks.each { |c| 2.times { |i| TiledVideo.take!(c, number: i + 1) } }

    assert_operator bare, :>, 0
    assert_equal bare, count.call, "takes on every chunk add no query"
  end
end
