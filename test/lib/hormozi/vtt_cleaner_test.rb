# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/hormozi/vtt_cleaner"

# [unit] THE ROLLING WINDOW SAYS EVERYTHING THREE TIMES. A YouTube auto-caption file is not
# a transcript: each cue repeats the tail of the one before and adds a few words, and each
# is emitted twice, once with inline `<00:00:04.480><c> word</c>` timings, once plain. Naive
# concatenation triples the corpus. The merge is by LONGEST word overlap, so the duplicate
# cue contributes nothing and the rolling cue only its new words.
# History: task hormozi-corpus-pipeline.
class VttCleanerTest < Minitest::Test
  ROLLING_WINDOW = <<~VTT
    WEBVTT
    Kind: captions
    Language: en

    00:00:03.360 --> 00:00:06.550 align:start position:0%
    mine who's competing in a fitness thing
    and<00:00:04.480><c> she</c><00:00:04.799><c> didn't</c><00:00:05.200><c> win</c>

    00:00:06.550 --> 00:00:06.560 align:start position:0%
    and she didn't win this fitness thing
  VTT

  def test_merges_the_rolling_window_into_each_sentence_once
    assert_equal(
      "mine who's competing in a fitness thing and she didn't win this fitness thing",
      Hormozi::VttCleaner.clean(ROLLING_WINDOW)
    )
  end

  def test_a_cue_that_only_repeats_its_predecessor_adds_nothing
    vtt = <<~VTT
      00:00:01.000 --> 00:00:02.000
      volume negates luck

      00:00:02.000 --> 00:00:03.000
      volume negates luck
    VTT

    assert_equal "volume negates luck", Hormozi::VttCleaner.clean(vtt)
  end

  def test_drops_headers_cue_timings_and_cue_numbers
    vtt = <<~VTT
      WEBVTT
      Kind: captions
      Language: en
      NOTE this is a note

      1
      00:00:01.000 --> 00:00:02.000 align:start position:0%
      the offer is the business
    VTT

    assert_equal "the offer is the business", Hormozi::VttCleaner.clean(vtt)
  end

  def test_decodes_entities_and_strips_inline_timing_tags
    vtt = <<~VTT
      00:00:01.000 --> 00:00:02.000
      leads<00:00:01.200><c> &amp;</c> offers aren&#39;t the same
    VTT

    assert_equal "leads & offers aren't the same", Hormozi::VttCleaner.clean(vtt)
  end

  def test_empty_input_is_an_empty_transcript_not_a_crash
    assert_equal "", Hormozi::VttCleaner.clean("")
    assert_equal "", Hormozi::VttCleaner.clean(nil)
  end

  # THE DEFECT: the language-tag class was lowercase-only, so a region-coded tag
  # kept its tag on the id. `P14HA83uNJE.en-US` then missed its metadata row, fell
  # back to the filename as its title, and tiered a real episode at 3 at exit 0 —
  # silent, and reachable the moment the fetch widens its --sub-langs.
  def test_derives_the_video_id_from_every_language_tag_yt_dlp_writes
    assert_equal "P14HA83uNJE", Hormozi::VttCleaner.video_id("P14HA83uNJE.en.vtt")
    assert_equal "P14HA83uNJE", Hormozi::VttCleaner.video_id("P14HA83uNJE.en-US.vtt")
    assert_equal "P14HA83uNJE", Hormozi::VttCleaner.video_id("P14HA83uNJE.pt-BR.vtt")
    assert_equal "P14HA83uNJE", Hormozi::VttCleaner.video_id("P14HA83uNJE.es-419.vtt")
    assert_equal "P14HA83uNJE", Hormozi::VttCleaner.video_id("P14HA83uNJE.vtt")
  end

  def test_derives_the_video_id_from_a_full_path
    assert_equal "P14HA83uNJE", Hormozi::VttCleaner.video_id("/corpus/hormozi/captions/P14HA83uNJE.en-US.vtt")
  end
end
