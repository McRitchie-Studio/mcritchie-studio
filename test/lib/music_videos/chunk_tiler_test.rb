# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/music_videos/chunk_tiler"

# [unit] The fixed tiling: 25 s chunks on a 20 s stride, the last one ending at
# the video's end, and no chunk for a tail the previous one already covers.
class MusicVideosChunkTilerTest < Minitest::Test
  Tiler = MusicVideos::ChunkTiler

  def spans(duration_ms) = Tiler.windows(duration_ms).map { |w| [w.start_ms, w.end_ms] }

  def test_the_plans_example_runs_0_25_20_45_40_65
    assert_equal [[0, 25_000], [20_000, 45_000], [40_000, 65_000]], spans(65_000)
    assert_equal [1, 2, 3], Tiler.windows(65_000).map(&:ordinal)
  end

  def test_a_video_shorter_than_one_chunk_is_one_short_chunk
    assert_equal [[0, 12_345]], spans(12_345)
    assert_equal [[0, 1]], spans(1)
  end

  def test_exactly_one_chunk_long_is_one_full_chunk
    assert_equal [[0, 25_000]], spans(25_000)
  end

  def test_a_tail_the_previous_chunk_covers_makes_no_extra_chunk
    # 45 s: the second chunk already ends at the end; a third from 40 s would repeat it.
    assert_equal [[0, 25_000], [20_000, 45_000]], spans(45_000)
    # A duration on a stride multiple: 40 s ends inside the second chunk.
    assert_equal [[0, 25_000], [20_000, 40_000]], spans(40_000)
    assert_equal [[0, 20_000]], spans(20_000)
  end

  def test_one_millisecond_past_a_chunk_end_adds_a_short_last_chunk
    assert_equal [[0, 25_000], [20_000, 25_001]], spans(25_001)
    assert_equal [[0, 25_000], [20_000, 45_000], [40_000, 45_001]], spans(45_001)
  end

  def test_between_stride_multiples_the_last_chunk_is_short_and_ends_at_the_end
    assert_equal [[0, 25_000], [20_000, 45_000], [40_000, 65_000], [60_000, 72_000]], spans(72_000)
  end

  def test_every_millisecond_is_covered_and_neighbours_overlap_five_seconds
    [1, 4_999, 20_000, 25_000, 25_001, 44_999, 45_000, 60_000, 72_000, 242_051, 600_000].each do |duration|
      list = Tiler.windows(duration)
      assert_equal 0, list.first.start_ms
      assert_equal duration, list.last.end_ms, "the last chunk ends at the video's end (#{duration})"
      list.each_with_index { |w, i| assert_equal Tiler.start_of(i + 1), w.start_ms }
      list[0..-2].each { |w| assert_equal Tiler::CHUNK_MS, w.end_ms - w.start_ms, "only the last chunk may be short" }
      list.each_cons(2) do |a, b|
        assert_equal Tiler::OVERLAP_MS, a.end_ms - b.start_ms
        assert b.end_ms > a.end_ms, "a chunk the previous one fully covers is never made (#{duration})"
      end
    end
  end

  def test_refuses_a_duration_it_cannot_tile
    [0, -1, 25.0, nil, "25000"].each { |bad| assert_raises(ArgumentError) { Tiler.windows(bad) } }
  end
end
