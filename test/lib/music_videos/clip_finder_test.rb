# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/music_videos/clip_finder"

# [unit] The seam picker on a synthetic song: a quiet intro, two energy steps,
# a dropout and a quiet outro. Every window must be 24-26 s of continuous music
# that starts on a boundary and spans a seam.
class MusicVideosClipFinderTest < Minitest::Test
  F = MusicVideos::ClipFinder

  # 150 s at 0.5 s frames. Intro 0-12 s, music 12-138 s, outro after.
  # Highs step up at 40 s (a chorus) and down at 55 s; silence at 100-101 s.
  def song(dropout: true)
    n = 300
    frame = ->(i) { i * F::FRAME_MS }
    music = ->(i) { frame.(i).between?(12_000, 137_999) }
    chorus = ->(i) { frame.(i).between?(40_000, 54_999) }
    silent = ->(i) { dropout && frame.(i).between?(100_000, 100_999) }
    level = lambda do |i, base, loud|
      next -80.0 if silent.(i)
      next -30.0 unless music.(i)

      base + (chorus.(i) ? loud : 0) + (i.even? ? 0.4 : -0.4)
    end
    { "low" => (0...n).map { |i| level.(i, -12.0, 0.5) }, "mid" => (0...n).map { |i| level.(i, -14.0, 0.5) },
      "high" => (0...n).map { |i| level.(i, -24.0, 6.0) }, "full" => (0...n).map { |i| level.(i, -8.0, 1.0) } }
  end

  def finder(**opts)
    F.new(bands: song, silences: [[100_000, 101_000]], cuts: [40_600, 55_300, 64_700], **opts)
  end

  def test_the_body_excludes_intro_and_outro
    body_start, body_end = finder.body
    assert_in_delta 12_000, body_start, 2_500
    assert_in_delta 138_000, body_end, 2_500
  end

  def test_energy_steps_are_boundaries_with_a_direction
    steps = finder.boundaries.select { |b| b.ms.between?(20_000, 90_000) }
    assert_equal [[40_000, "verse_to_chorus"], [55_000, "chorus_to_verse"]], steps.map { |b| [b.ms, b.seam] }
  end

  def test_windows_are_continuous_music_of_24_to_26_seconds
    proposals = finder.proposals
    refute_empty proposals
    body_start, body_end = finder.body

    proposals.each do |p|
      assert_includes 24_000..26_000, p.end_ms - p.start_ms, "clip #{p.ordinal} length"
      assert p.start_ms >= body_start && p.end_ms <= body_end, "clip #{p.ordinal} inside the music"
      refute p.start_ms < 101_000 && 100_000 < p.end_ms, "clip #{p.ordinal} crosses the dropout"
      assert p.seam_ms.between?(p.start_ms + F::SEAM_MARGIN_MS, p.end_ms - F::SEAM_MARGIN_MS), "seam inside"
      assert_includes F::SEAMS, p.seam
    end
    assert_equal (1..proposals.size).to_a, proposals.map(&:ordinal)
    proposals.each_cons(2) { |a, b| assert a.end_ms <= b.start_ms, "windows do not overlap" }
  end

  def test_starts_snap_to_a_cut_near_the_boundary_and_ends_to_a_cut_near_25_seconds
    clip = finder.proposals.find { |p| p.seam == "chorus_to_verse" }

    assert_equal 40_600, clip.start_ms, "the 40 s step snaps to the cut 0.6 s later"
    assert_equal 64_700, clip.end_ms, "a cut at 24.1 s beats the bare 25 s mark"
    assert_equal 55_000, clip.seam_ms, "the step down, 14.4 s in"
  end

  def test_no_window_crosses_a_dropout_even_when_silencedetect_missed_it
    f = F.new(bands: song, silences: [], cuts: [])
    f.proposals.each { |p| refute p.start_ms < 101_000 && 100_000 < p.end_ms }
  end

  def test_a_window_with_no_seam_inside_is_not_proposed
    flat = song.transform_values { |levels| levels.each_with_index.map { |db, i| i.between?(24, 275) ? -10.0 : db } }
    assert_empty F.new(bands: flat).proposals
  end

  def test_a_singer_handover_is_a_seam_and_labels_the_cast
    cast = [{ "ordinal" => 1, "artist_slug" => "a", "extra" => false,
              "sightings" => [104, 107, 110].map { |t| { "t_ms" => t * 1000, "visibility" => "clear" } } },
            { "ordinal" => 2, "artist_slug" => "b", "extra" => false,
              "sightings" => [113, 116, 119].map { |t| { "t_ms" => t * 1000, "visibility" => "clear" } } }]
    sections = [{ "kind" => "vocal", "start_ms" => 12_000, "end_ms" => 50_000 },
                { "kind" => "instrumental", "start_ms" => 102_000, "end_ms" => 110_000 }]
    clip = F.new(bands: song, silences: [[100_000, 101_000]], sections:, performers: cast).proposals
            .find { |p| p.seam == "singer_change" }

    assert clip, "the caption section at 102 s opens a window that spans the 111.5 s handover"
    assert_equal 111_500, clip.seam_ms
    assert_equal "duo", clip.cast_shape
    assert_includes [1, 2], clip.target_performer
    assert_equal [1, 2], clip.performer_ordinals
  end

  def test_count_limits_the_proposals
    assert_equal 1, finder(count: 1).proposals.size
  end
end
