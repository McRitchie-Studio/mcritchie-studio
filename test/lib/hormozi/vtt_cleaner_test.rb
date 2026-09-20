# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/hormozi/vtt_cleaner"

# [unit] THE ROLLING WINDOW SAYS EVERYTHING THREE TIMES — and a transcript that
# says everything three times is what we would have paid an extraction pass to
# read.
#
# THE SHAPE OF THE DEFECT. A YouTube auto-caption file is not a transcript. Each
# cue repeats the tail of the cue before it and adds a few new words, and each
# cue is emitted twice: once carrying inline `<00:00:04.480><c> word</c>`
# timings, once plain. Naively concatenating the cue text triples the corpus.
#
# WHAT THAT COSTS. The fixture below is nine spoken words. Concatenated
# naively it is nineteen — so a 600-hour corpus bills as 1,800 hours of
# reading, and the extraction agent spends its context re-reading a stutter
# instead of learning the method. The merge is by LONGEST word overlap, so the
# duplicate cue contributes nothing and the rolling cue contributes only its
# new words.
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
end
