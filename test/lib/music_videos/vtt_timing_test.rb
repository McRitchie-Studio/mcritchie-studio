# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../../../lib/music_videos/vtt_timing"

# [unit] A caption file becomes cue timings and section markers. No word of the
# caption text may survive into the result.
class MusicVideosVttTimingTest < Minitest::Test
  VTT = <<~VTT
    WEBVTT
    Kind: captions
    Language: en

    00:00:00.000 --> 00:00:04.500 align:start position:0%
    [Music]

    00:00:05.000 --> 00:00:07.000 align:start position:0%
    secretlyric<00:00:05.500><c> alpha</c>

    00:00:07.000 --> 00:00:07.010 align:start position:0%
    secretlyric alpha

    00:00:07.010 --> 00:00:09.250
    bravo words here

    00:00:15.000 --> 00:00:17.000
    charlie line

    01:00:00.000 --> 01:00:02.000
    ♪ ♪
  VTT

  def result
    MusicVideos::VttTiming.parse(VTT)
  end

  def test_vocal_cues_keep_only_start_and_end
    assert_equal [
      { "start_ms" => 5_000, "end_ms" => 7_000 },
      { "start_ms" => 7_010, "end_ms" => 9_250 },
      { "start_ms" => 15_000, "end_ms" => 17_000 }
    ], result["cues"]
  end

  def test_sections_split_on_gaps_and_music_tags
    assert_equal [
      { "kind" => "instrumental", "start_ms" => 0, "end_ms" => 4_500 },
      { "kind" => "vocal", "start_ms" => 5_000, "end_ms" => 9_250 },
      { "kind" => "vocal", "start_ms" => 15_000, "end_ms" => 17_000 },
      { "kind" => "instrumental", "start_ms" => 3_600_000, "end_ms" => 3_602_000 }
    ], result["sections"]
  end

  def test_no_caption_text_survives
    json = JSON.generate(result)
    %w[secretlyric alpha bravo charlie Music].each { |word| refute_includes json, word }
    assert_equal %w[cues sections], result.keys
  end

  def test_empty_or_missing_input_is_empty_timing
    assert_equal({ "cues" => [], "sections" => [] }, MusicVideos::VttTiming.parse(""))
    assert_equal({ "cues" => [], "sections" => [] }, MusicVideos::VttTiming.parse(nil))
  end
end
