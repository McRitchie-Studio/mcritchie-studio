# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/music_videos/object_keys"

# [unit] The snake_case R2 tree from the pipeline plan.
class MusicVideosObjectKeysTest < Minitest::Test
  def test_night_call_keys
    keys = MusicVideos::ObjectKeys.new(primary: ["Steve Aoki"], featured: ["Lil Yachty", "Migos"], song: "Night Call")
    assert_equal "music_videos/steve_aoki/night_call/source/steve_aoki_night_call_feat_lil_yachty_migos.mp4",
                 keys.source_mp4
    assert_equal "music_videos/steve_aoki/night_call/source/steve_aoki_night_call_feat_lil_yachty_migos.info.json",
                 keys.info_json
  end

  def test_no_featured_and_accents_and_symbols
    keys = MusicVideos::ObjectKeys.new(primary: ["Beyoncé", "A$AP Rocky"], featured: [], song: "Déjà Vu!")
    assert_equal "music_videos/beyonce/deja_vu/source/beyonce_a_ap_rocky_deja_vu.mp4", keys.source_mp4
  end

  def test_refuses_a_blank_segment
    assert_raises(ArgumentError) { MusicVideos::ObjectKeys.new(primary: [], featured: [], song: "X").source_mp4 }
    assert_raises(ArgumentError) { MusicVideos::ObjectKeys.new(primary: ["A"], featured: [], song: "!!").source_mp4 }
  end
end
