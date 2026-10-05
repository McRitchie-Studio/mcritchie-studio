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

# [unit] Clip keys sit in the source's folder and spell out the window.
class MusicVideosClipKeyTest < Minitest::Test
  SOURCE = "music_videos/steve_aoki/night_call/source/steve_aoki_night_call_feat_lil_yachty_migos.mp4"

  def test_clip_key_names_ordinal_seam_shape_and_times
    key = MusicVideos::ObjectKeys.clip(source_key: SOURCE, ordinal: 3, seam: "verse_to_chorus",
                                       cast_shape: "duo_plus_background", start_ms: 93_400, end_ms: 118_400)
    assert_equal "music_videos/steve_aoki/night_call/clips/night_call_clip_03_verse_to_chorus_duo_plus_background_0133_0158.mp4", key
  end

  def test_chunk_key_sits_beside_the_clips_and_names_ordinal_and_times
    key = MusicVideos::ObjectKeys.chunk(source_key: SOURCE, ordinal: 12, start_ms: 220_000, end_ms: 242_051)
    assert_equal "music_videos/steve_aoki/night_call/chunks/night_call_chunk_12_0340_0402.mp4", key
  end

  def test_chunk_key_refuses_a_source_outside_the_tree
    assert_raises(ArgumentError) { MusicVideos::ObjectKeys.chunk(source_key: "other/x.mp4", ordinal: 1, start_ms: 0, end_ms: 25_000) }
  end

  def test_refuses_a_key_outside_the_tree
    assert_raises(ArgumentError) do
      MusicVideos::ObjectKeys.clip(source_key: "other/x.mp4", ordinal: 1, seam: "unknown", cast_shape: "solo",
                                   start_ms: 0, end_ms: 25_000)
    end
  end
end
