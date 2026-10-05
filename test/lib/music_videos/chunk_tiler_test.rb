# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/music_videos/chunk_tiler"

# [unit] The tiling: by default 25 s chunks on a 20 s stride, the last one
# ending at the video's end, and no chunk for a tail the previous one already
# covers. Chunk length and overlap are parameters (15 s / 5 s for the fal model).
class MusicVideosChunkTilerTest < Minitest::Test
  Tiler = MusicVideos::ChunkTiler

  def spans(duration_ms, **tiling) = Tiler.windows(duration_ms, **tiling).map { |w| [w.start_ms, w.end_ms] }

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

  def test_every_millisecond_is_covered_and_neighbours_overlap_by_the_overlap
    [[25_000, 5_000], [15_000, 5_000], [10_000, 0], [3_000, 1_000]].each do |chunk_ms, overlap_ms|
      [1, 4_999, 10_000, 15_000, 15_001, 20_000, 25_000, 25_001, 44_999, 45_000, 60_000, 72_000, 242_051].each do |duration|
        list = Tiler.windows(duration, chunk_ms:, overlap_ms:)
        assert_equal 0, list.first.start_ms
        assert_equal duration, list.last.end_ms, "the last chunk ends at the video's end (#{duration})"
        list.each_with_index { |w, i| assert_equal Tiler.start_of(i + 1, chunk_ms:, overlap_ms:), w.start_ms }
        list[0..-2].each { |w| assert_equal chunk_ms, w.end_ms - w.start_ms, "only the last chunk may be short" }
        list.each_cons(2) do |a, b|
          assert_equal overlap_ms, a.end_ms - b.start_ms
          assert b.end_ms > a.end_ms, "a chunk the previous one fully covers is never made (#{duration})"
        end
      end
    end
  end

  # The fal swap model takes 3 to 15 s inputs: 15 s chunks, 5 s overlap, a 10 s stride.
  def test_a_15_second_chunk_with_a_5_second_overlap_tiles_on_a_10_second_stride
    tiling = { chunk_ms: 15_000, overlap_ms: 5_000 }
    assert_equal 10_000, Tiler.stride(**tiling)
    assert_equal [[0, 15_000], [10_000, 25_000], [20_000, 35_000], [30_000, 45_000]], spans(45_000, **tiling)
    assert_equal [[0, 15_000], [10_000, 25_000], [20_000, 35_000], [30_000, 45_000], [40_000, 47_500]], spans(47_500, **tiling)
    assert_equal [[0, 15_000]], spans(15_000, **tiling)
    assert_equal [[0, 15_000], [10_000, 15_001]], spans(15_001, **tiling)
    assert_equal [[0, 15_000], [10_000, 25_000]], spans(25_000, **tiling), "the covered tail makes no third chunk"
    assert_equal [[0, 9_000]], spans(9_000, **tiling)
    assert_equal 7, Tiler.windows(72_000, **tiling).size, "0-15 ... 60-72, where the default tiling makes four"
    assert_equal 30_000, Tiler.start_of(4, **tiling)
  end

  def test_the_defaults_are_25_seconds_with_a_5_second_overlap
    assert_equal [25_000, 5_000, 20_000], [Tiler::CHUNK_MS, Tiler::OVERLAP_MS, Tiler::STRIDE_MS]
    assert_equal spans(72_000), spans(72_000, chunk_ms: 25_000, overlap_ms: 5_000)
  end

  def test_no_overlap_is_a_plain_cut
    assert_equal [[0, 10_000], [10_000, 20_000], [20_000, 24_000]], spans(24_000, chunk_ms: 10_000, overlap_ms: 0)
  end

  def test_an_overlap_as_long_as_the_chunk_cannot_tile
    assert_match "must be shorter than the chunk", Tiler.problem(chunk_ms: 15_000, overlap_ms: 15_000)
    assert_match "must be shorter than the chunk", Tiler.problem(chunk_ms: 15_000, overlap_ms: 20_000)
    assert_match "chunk length", Tiler.problem(chunk_ms: 0, overlap_ms: 0)
    assert_match "chunk length", Tiler.problem(chunk_ms: 15.0, overlap_ms: 5_000)
    assert_match "overlap", Tiler.problem(chunk_ms: 15_000, overlap_ms: -1)
    assert_match "overlap", Tiler.problem(chunk_ms: 15_000, overlap_ms: nil)
    assert_nil Tiler.problem(chunk_ms: 15_000, overlap_ms: 14_999)
    assert_raises(ArgumentError) { Tiler.windows(60_000, chunk_ms: 15_000, overlap_ms: 15_000) }
    assert_raises(ArgumentError) { Tiler.start_of(2, chunk_ms: 5_000, overlap_ms: 9_000) }
  end

  def test_refuses_a_duration_it_cannot_tile
    [0, -1, 25.0, nil, "25000"].each { |bad| assert_raises(ArgumentError) { Tiler.windows(bad) } }
  end
end
