require "test_helper"

# [unit] The stage transition guard: digested -> cast_confirmed only when there
# are performers and each is an artist or an extra. Plus the timecode link.
class MusicVideoCastTest < ActiveSupport::TestCase
  setup do
    @video = MusicVideo.create!(slug: "night-call", platform: "youtube", source_url: "https://www.youtube.com/watch?v=Sa7",
                                source_id: "Sa7", title: "Night Call",
                                source_object_key: "music_videos/steve_aoki/night_call/source/a.mp4")
    Artist.create!(slug: "lil-yachty", name: "Lil Yachty", kind: "person")
  end

  def add(ordinal, **attrs) = @video.video_performers.create!(ordinal:, label: "person #{ordinal}", **attrs)

  test "no performers yet: not ready, and confirming refuses" do
    assert_not @video.cast_ready?
    error = assert_raises(MusicVideo::CastNotReady) { @video.confirm_cast! }
    assert_match "no performers yet", error.message
    assert_equal "digested", @video.reload.stage
  end

  test "an open performer blocks the confirm and is named" do
    add(1, artist_slug: "lil-yachty")
    add(2)
    add(3)

    error = assert_raises(MusicVideo::CastNotReady) { @video.confirm_cast! }
    assert_equal "Person 2 and Person 3 are neither an artist nor an extra", error.message
    assert_equal "digested", @video.reload.stage
  end

  test "artists and extras together confirm the cast, once" do
    add(1, artist_slug: "lil-yachty")
    add(2, extra: true)

    assert @video.cast_ready?
    @video.confirm_cast!
    assert_equal "cast_confirmed", @video.reload.stage
    assert @video.cast_confirmed?
    assert_not @video.cast_ready?
    assert_raises(MusicVideo::CastNotReady) { @video.confirm_cast! }
  end

  test "a YouTube timecode link adds t= in whole seconds; other platforms have none" do
    assert_equal "https://www.youtube.com/watch?v=Sa7&t=83s", @video.timecode_url(83_900)
    assert_equal "https://youtu.be/Sa7?t=5s", MusicVideo.new(platform: "youtube", source_url: "https://youtu.be/Sa7").timecode_url(5_000)
    assert_nil MusicVideo.new(platform: "tiktok", source_url: "https://tiktok.com/x").timecode_url(5_000)
  end
end
