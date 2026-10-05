# frozen_string_literal: true

require "test_helper"

# [unit] The stitch preview's timeline: each chunk is on screen from the middle
# of the overlap it shares with the chunk before to the middle of the overlap
# with the chunk after, timed from the recorded windows alone.
class MusicVideos::StitchTimelineTest < ActiveSupport::TestCase
  Timeline = MusicVideos::StitchTimeline
  Tiler = MusicVideos::ChunkTiler

  def spans(segments) = segments.map { |s| [s.ordinal, s.from_ms, s.to_ms] }

  test "the default tiling hands over at the middle of each 5 s overlap" do
    segments = Timeline.segments(Tiler.windows(72_000))

    assert_equal [[1, 0, 22_500], [2, 22_500, 42_500], [3, 42_500, 62_500], [4, 62_500, 72_000]], spans(segments)
    assert_equal 72_000, Timeline.duration_ms(segments)
  end

  test "the segments cover the whole video once, with no gap and no repeat" do
    [[128_600, 25_000, 5_000], [61_000, 15_000, 3_000], [40_000, 25_000, 0], [9_000, 25_000, 5_000]].each do |duration, chunk_ms, overlap_ms|
      segments = Timeline.segments(Tiler.windows(duration, chunk_ms:, overlap_ms:))

      assert_equal 0, segments.first.from_ms
      assert_equal duration, segments.last.to_ms
      segments.each_cons(2) { |left, right| assert_equal left.to_ms, right.from_ms }
      segments.each { |s| assert_operator s.from_ms, :<, s.to_ms }
    end
  end

  test "another tiling moves the handover with its overlap" do
    segments = Timeline.segments(Tiler.windows(40_000, chunk_ms: 15_000, overlap_ms: 3_000))

    # 0-15, 12-27, 24-39, 36-40: the overlaps are 12-15, 24-27, 36-39.
    assert_equal [[1, 0, 13_500], [2, 13_500, 25_500], [3, 25_500, 37_500], [4, 37_500, 40_000]], spans(segments)
  end

  test "a plain cut hands over where the next chunk starts" do
    segments = Timeline.segments(Tiler.windows(50_000, chunk_ms: 25_000, overlap_ms: 0))

    assert_equal [[1, 0, 25_000], [2, 25_000, 50_000]], spans(segments)
  end

  test "an odd overlap rounds the handover down to a whole millisecond" do
    left = Tiler::Window.new(ordinal: 1, start_ms: 0, end_ms: 10_001)
    right = Tiler::Window.new(ordinal: 2, start_ms: 9_000, end_ms: 19_000)

    assert_equal 9_500, Timeline.handover_ms(left, right)
    assert_equal 12_000, Timeline.handover_ms(left, Tiler::Window.new(ordinal: 2, start_ms: 12_000, end_ms: 20_000)),
                 "a gap: the next chunk takes over at its own start"
  end

  test "the offset into a chunk's file comes from its recorded start, not a file length" do
    second = Timeline.segments(Tiler.windows(72_000)).second

    assert_equal 2_500, second.offset_ms(second.from_ms), "chunk 2 enters 2.5 s into its own file"
    assert_equal 22_500, second.offset_ms(second.to_ms)
  end

  test "segment_at finds the chunk on screen, the handover instant belonging to the next" do
    segments = Timeline.segments(Tiler.windows(72_000))

    assert_equal 1, Timeline.segment_at(segments, 0).ordinal
    assert_equal 1, Timeline.segment_at(segments, 22_499).ordinal
    assert_equal 2, Timeline.segment_at(segments, 22_500).ordinal
    assert_equal 4, Timeline.segment_at(segments, 71_999).ordinal
    assert_equal 4, Timeline.segment_at(segments, 90_000).ordinal, "past the end stays on the last chunk"
    assert_equal 1, Timeline.segment_at(segments, -5).ordinal
    assert segments.second.cover?(22_500)
    assert_not segments.second.cover?(42_500)
  end

  test "one chunk is the whole video, and none is an empty timeline" do
    assert_equal [[1, 0, 9_000]], spans(Timeline.segments(Tiler.windows(9_000)))
    assert_empty Timeline.segments([])
    assert_equal 0, Timeline.duration_ms([])
    assert_nil Timeline.segment_at([], 0)
  end

  test "windows that do not run forward are refused" do
    windows = Tiler.windows(72_000)

    error = assert_raises(ArgumentError) { Timeline.segments(windows.reverse) }
    assert_match(/chunk 3 does not run on from chunk 4/, error.message)
  end
end
