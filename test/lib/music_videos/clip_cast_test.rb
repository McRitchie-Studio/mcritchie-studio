# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/music_videos/clip_cast"

# [unit] Cast-shape labelling from the confirmed cast's sightings.
class MusicVideosClipCastTest < Minitest::Test
  C = MusicVideos::ClipCast

  def person(ordinal, clear: [], partial: [], artist: "a-#{ordinal}", extra: false)
    { "ordinal" => ordinal, "artist_slug" => artist, "extra" => extra,
      "sightings" => clear.map { |t| { "t_ms" => t * 1000, "visibility" => "clear" } } +
        partial.map { |t| { "t_ms" => t * 1000, "visibility" => "partial" } } }
  end

  def test_solo_targets_the_only_principal
    label = C.label([person(1, clear: [10, 13, 16]), person(2, clear: [60])], 9_000, 34_000)

    assert_equal "solo", label.cast_shape
    assert_equal 1, label.target
    assert_equal [1], label.present
  end

  def test_extras_and_partial_sightings_are_background
    cast = [person(1, clear: [10, 13]), person(2, clear: [12, 20, 22]),
            person(3, clear: [15], artist: nil, extra: true), person(4, partial: [18])]
    label = C.label(cast, 9_000, 34_000)

    assert_equal "duo_plus_background", label.cast_shape
    assert_equal 2, label.target, "the principal seen clearly most"
    assert_equal [1, 2, 3, 4], label.present
  end

  def test_trio_group_and_unknown
    three = (1..3).map { |n| person(n, clear: [10 + n]) }
    assert_equal "trio", C.label(three, 9_000, 34_000).cast_shape
    assert_equal "group", C.label(three + [person(4, clear: [20]), person(5, clear: [21])], 9_000, 34_000).cast_shape

    only_extras = C.label([person(1, clear: [10], artist: nil, extra: true)], 9_000, 34_000)
    assert_equal "unknown", only_extras.cast_shape
    assert_nil only_extras.target
  end

  def test_a_sighting_just_outside_counts_within_half_a_sample
    assert_equal [1], C.label([person(1, clear: [35])], 9_000, 34_000).present
    assert_empty C.label([person(1, clear: [36])], 9_000, 34_000).present
  end

  def test_singer_changes_are_handovers_between_lone_principals
    cast = [person(1, clear: [10, 13, 16]), person(2, clear: [19, 22, 40]),
            person(3, clear: [22], artist: nil, extra: true)]

    assert_equal [17_500], C.singer_changes(cast), "22 s has a lone principal (an extra does not count); 22 -> 40 is too far apart"
  end
end
