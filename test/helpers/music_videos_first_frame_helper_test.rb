# frozen_string_literal: true

require "test_helper"

# [unit] first_frame_src: the media fragment that makes a clip's player open on
# its first frame. The fragment rides after the signed query, so the signature
# is untouched; a URL that already carries a fragment, or none at all, is left
# alone.
class MusicVideosFirstFrameHelperTest < ActionView::TestCase
  include MusicVideosHelper

  test "appends the first-frame fragment after a signed query" do
    url = "https://bucket.example/music_videos/a/b/chunks/b_chunk_01_0000_0025.mp4?X-Amz-Expires=3600&X-Amz-Signature=abc"
    assert_equal "#{url}#t=0.001", first_frame_src(url)
  end

  test "leaves a URL that already has a fragment, and a blank one, alone" do
    assert_equal "https://x.example/v.mp4#t=5", first_frame_src("https://x.example/v.mp4#t=5")
    assert_nil first_frame_src(nil)
    assert_equal "", first_frame_src("")
  end
end
