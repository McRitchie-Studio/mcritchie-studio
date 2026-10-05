# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [unit] A chunk's generated takes: which take is current, the regenerate flag,
# what survives a re-tile, and the predicate the final stitch reads.
class VideoChunkTakeTest < ActiveSupport::TestCase
  setup do
    @video = TiledVideo.seed!
    @chunks = @video.video_chunks.to_a
    @chunk = @chunks.second
  end

  def take!(chunk, number, at: Time.current)
    TiledVideo.take!(chunk, number:, at:)
  end

  def chunk(ordinal) = @video.reload.video_chunks.find { |c| c.ordinal == ordinal }

  test "a take is filed under the video's generated folder, named for its chunk and number" do
    take = take!(@chunk, 3)

    assert_equal "music_videos/test_artist_a/tiled_demo/generated/tiled_demo_chunk_02_0020_0045_take_03.mp4", take.object_key
    assert_equal "Take 3", take.name
    assert take.for?(@chunk)
    assert_not take.for?(@chunks.first)
    assert_not take.for?(@video.clip_candidates.sole)
  end

  test "a take whose key does not name it, or that repeats a number, is refused" do
    take = take!(@chunk, 1)
    twin = take.dup
    take.object_key = take.object_key.sub("take_01", "take_02")
    assert_not take.valid?
    assert_match(/must be .*take_01\.mp4/, take.errors[:object_key].sole)

    assert_not twin.valid?
    assert twin.errors.key?(:number)
    assert_raises(ActiveRecord::RecordNotUnique) { twin.save!(validate: false) }
  end

  test "a chunk with no take has no current take and plays its own source cut" do
    assert_empty @chunk.takes
    assert_nil @chunk.current_take
    assert_equal @chunk.object_key, @chunk.playback_object_key
  end

  test "the newest take is current until the operator puts an older one back" do
    first = take!(@chunk, 1, at: 3.minutes.ago)
    second = take!(@chunk, 2, at: 2.minutes.ago)

    assert_equal [1, 2], chunk(2).takes.map(&:number)
    assert_equal second, chunk(2).current_take
    assert_equal second.object_key, chunk(2).playback_object_key

    first.make_current!
    assert_equal first, chunk(2).current_take

    third = take!(chunk(2), 3)
    assert_equal third, chunk(2).current_take, "a new upload is current again"
    assert_equal [1, 2, 3], chunk(2).takes.map(&:number), "every take is kept"
  end

  test "make_current! wins even against a sibling stamped at the same instant or later" do
    at = Time.current.change(usec: 0)
    first = take!(@chunk, 1, at:)
    take!(@chunk, 2, at: at + 1.hour)

    first.make_current!(at:)
    assert_equal first, chunk(2).current_take
  end

  test "takes belong to their own chunk only" do
    take!(@chunks.first, 1)

    assert_equal 1, chunk(1).takes.size
    assert_empty chunk(2).takes
    assert_empty @video.clip_candidates.sole.takes, "a clip candidate has no takes"
  end

  test "request regenerate flags the chunk with a squished optional note; clear removes both" do
    assert_not @chunk.regenerate_requested?

    @chunk.request_regenerate!("  the jersey   flickers  ")
    assert @chunk.reload.regenerate_requested?
    assert_equal "the jersey flickers", @chunk.regenerate_note
    assert_equal [2], @video.reload.chunks_flagged.map(&:ordinal)

    @chunk.request_regenerate!("")
    assert_nil @chunk.reload.regenerate_note
    assert @chunk.regenerate_requested?

    @chunk.clear_regenerate!
    assert_not @chunk.reload.regenerate_requested?
    assert_empty @video.reload.chunks_flagged
  end

  test "a regenerate note over the limit and a flag on a clip candidate are refused" do
    @chunk.regenerate_note = "x" * (VideoClip::REGENERATE_NOTE_MAX + 1)
    assert_not @chunk.valid?

    candidate = @video.clip_candidates.sole
    candidate.regenerate_requested_at = Time.current
    assert_not candidate.valid?
    assert_match(/is for a chunk/, candidate.errors[:regenerate_requested_at].sole)
  end

  test "ready to stitch needs a current take on every chunk and no flag" do
    assert_not @video.ready_to_stitch?
    assert_equal "Chunk 1, Chunk 2, Chunk 3, and Chunk 4 have no generated take", @video.stitch_blocker

    @chunks.first(3).each { |c| take!(c, 1) }
    assert_not @video.reload.ready_to_stitch?
    assert_equal [4], @video.chunks_without_take.map(&:ordinal)
    assert_equal "Chunk 4 has no generated take", @video.stitch_blocker

    take!(@chunks.last, 1)
    assert @video.reload.ready_to_stitch?
    assert_nil @video.stitch_blocker

    chunk(3).request_regenerate!("hands")
    assert_not @video.reload.ready_to_stitch?
    assert_equal "Chunk 3 is flagged for a regenerate", @video.stitch_blocker

    chunk(3).clear_regenerate!
    assert @video.reload.ready_to_stitch?
  end

  test "a video with no chunks is never ready to stitch" do
    @video.video_chunks.destroy_all

    assert_not @video.reload.ready_to_stitch?
    assert_equal "the video is not tiled into chunks yet", @video.stitch_blocker
  end

  test "a re-tile at the same windows keeps each chunk's takes and its regenerate flag" do
    take!(@chunk, 1)
    @chunk.request_regenerate!("the jersey flickers")

    MusicVideos::ReplaceClips.new(@video, TiledVideo.chunk_rows(@video), kind: "chunk").call
    again = chunk(2)

    assert_not_equal @chunk.id, again.id, "the chunk rows were replaced"
    assert_equal [1], again.takes.map(&:number)
    assert again.regenerate_requested?
    assert_equal "the jersey flickers", again.regenerate_note
    assert_not chunk(1).regenerate_requested?
  end

  test "a re-tile at another chunk length leaves the old takes filed but belonging to no chunk" do
    take!(@chunks.first, 1)
    take!(@chunk, 1)
    @chunk.request_regenerate!

    tiling = { chunk_ms: 15_000, overlap_ms: 3_000 }
    MusicVideos::ReplaceClips.new(@video, TiledVideo.chunk_rows(@video, **tiling), kind: "chunk",
                                  chunk_ms: tiling[:chunk_ms], chunk_overlap_ms: tiling[:overlap_ms]).call

    assert_equal 2, @video.reload.chunk_takes.count, "the takes are kept"
    assert @video.video_chunks.all? { |c| c.takes.empty? && !c.regenerate_requested? }
    assert_not @video.ready_to_stitch?
  end

  test "destroying the video drops its take rows" do
    take!(@chunk, 1)

    assert_difference -> { VideoChunkTake.count }, -1 do
      @video.destroy!
    end
  end
end
