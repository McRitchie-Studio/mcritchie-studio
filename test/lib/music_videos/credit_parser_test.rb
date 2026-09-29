# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/music_videos/credit_parser"

# [unit] Splits a video's title/uploader/info credits into primary and featured
# names. Pure Ruby: the agent script loads it without Rails.
class MusicVideosCreditParserTest < Minitest::Test
  def parse(title, uploader: nil, artists: [], known: [])
    names = known.map(&:downcase)
    MusicVideos::CreditParser.new(known: ->(n) { names.include?(n.downcase) })
                             .parse(title: title, uploader: uploader, artists: artists)
  end

  def test_night_call_title
    r = parse("Steve Aoki - Night Call feat. Lil Yachty & Migos (Official Video) [Ultra Music]",
              uploader: "Ultra Records")
    assert_equal ["Steve Aoki"], r.primary
    assert_equal ["Lil Yachty", "Migos"], r.featured
    assert_equal "Night Call", r.song
  end

  def test_ft_in_parentheses_and_comma_list
    r = parse("Drake - Nice For What (ft. Future, 21 Savage and Travis Scott) [Official Audio]")
    assert_equal ["Drake"], r.primary
    assert_equal ["Future", "21 Savage", "Travis Scott"], r.featured
    assert_equal "Nice For What", r.song
  end

  def test_x_joins_primaries_and_with_in_brackets_features
    r = parse("Marshmello x Bastille - Happier (with Anne-Marie) (Official Music Video)")
    assert_equal ["Marshmello", "Bastille"], r.primary
    assert_equal ["Anne-Marie"], r.featured
    assert_equal "Happier", r.song
  end

  def test_feat_on_the_artist_side
    r = parse("Travis Scott featuring Drake – SICKO MODE")
    assert_equal ["Travis Scott"], r.primary
    assert_equal ["Drake"], r.featured
    assert_equal "SICKO MODE", r.song
  end

  def test_bare_with_in_a_song_title_is_not_a_credit
    r = parse("Billy Idol - Dancing with Myself")
    assert_equal ["Billy Idol"], r.primary
    assert_equal [], r.featured
    assert_equal "Dancing with Myself", r.song
  end

  def test_known_name_with_a_separator_stays_whole
    r = parse("Tyler, The Creator & Kali Uchis - See You Again",
              known: ["Tyler, The Creator", "Earth, Wind & Fire"])
    assert_equal ["Tyler, The Creator", "Kali Uchis"], r.primary
    r = parse("Earth, Wind & Fire - September", known: ["Earth, Wind & Fire"])
    assert_equal ["Earth, Wind & Fire"], r.primary
  end

  def test_no_dash_falls_back_to_info_artists_then_uploader
    r = parse("Night Call", artists: ["Steve Aoki", "Lil Yachty"])
    assert_equal ["Steve Aoki"], r.primary
    assert_equal ["Lil Yachty"], r.featured
    r = parse("Night Call (Official Video)", uploader: "SteveAokiVEVO")
    assert_equal ["SteveAoki"], r.primary
    r = parse("Night Call", uploader: "Steve Aoki - Topic")
    assert_equal ["Steve Aoki"], r.primary
  end

  def test_info_artists_add_missing_featured_without_duplicates
    r = parse("Steve Aoki - Night Call feat. Lil Yachty", artists: ["steve aoki", "Migos"])
    assert_equal ["Steve Aoki"], r.primary
    assert_equal ["Lil Yachty", "Migos"], r.featured
  end

  def test_lowercase_x_inside_a_name_is_not_a_separator
    r = parse("Lil Nas X - Old Town Road")
    assert_equal ["Lil Nas X"], r.primary
  end
end
