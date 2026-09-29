require "test_helper"

# [unit] A performer's shape: sightings are times and a visibility, stills live
# under the video's own folder and carry the performer's number.
class VideoPerformerTest < ActiveSupport::TestCase
  setup do
    @video = MusicVideo.create!(slug: "night-call", platform: "youtube", source_url: "https://www.youtube.com/watch?v=x",
                                source_id: "x", title: "Night Call",
                                source_object_key: "music_videos/steve_aoki/night_call/source/a.mp4")
  end

  def performer(**attrs)
    @video.video_performers.new({ ordinal: 1, label: "desk",
                                  still_object_keys: ["music_videos/steve_aoki/night_call/stills/person_01_0230.jpg"],
                                  sightings: [{ "t_ms" => 18_000, "visibility" => "clear" }] }.merge(attrs))
  end

  test "a well-formed performer is valid and open" do
    p = performer
    assert p.valid?, p.errors.full_messages.inspect
    assert_equal "Person 1", p.name
    assert_not p.resolved?
  end

  test "sightings carry only an integer time and clear or partial" do
    assert_not performer(sightings: [{ "t_ms" => "18s", "visibility" => "clear" }]).valid?
    assert_not performer(sightings: [{ "t_ms" => 18_000, "visibility" => "blurry" }]).valid?
    assert_not performer(sightings: [{ "t_ms" => 18_000, "visibility" => "clear", "face" => "x" }]).valid?
    assert_not performer(sightings: [{ "t_ms" => -1, "visibility" => "clear" }]).valid?
    assert performer(sightings: []).valid?
  end

  test "stills sit in this video's stills folder and are numbered for this person" do
    assert_not performer(still_object_keys: ["music_videos/drake/hotline_bling/stills/person_01_0230.jpg"]).valid?
    assert_not performer(still_object_keys: ["music_videos/steve_aoki/night_call/stills/person_02_0230.jpg"]).valid?
    assert_not performer(still_object_keys: ["music_videos/steve_aoki/night_call/stills/p1.png"]).valid?
    assert performer(still_object_keys: []).valid?
  end

  test "an artist or an extra resolves it, never both" do
    Artist.create!(slug: "test-artist-a", name: "Test Artist A", kind: "person")

    assert performer(artist_slug: "test-artist-a").resolved?
    assert performer(extra: true).resolved?
    assert_not performer(artist_slug: "test-artist-a", extra: true).valid?
  end

  test "ordinal is unique within a video" do
    performer.save!

    assert_not performer(still_object_keys: []).valid?
  end

  test "reference stills rank clear before partial before unsighted, posted order breaking ties" do
    dir = "music_videos/steve_aoki/night_call/stills/person_01_"
    p = performer(
      still_object_keys: %W[#{dir}0306.jpg #{dir}0500.jpg #{dir}0042.jpg #{dir}0230.jpg],
      sightings: [{ "t_ms" => 186_000, "visibility" => "partial" }, { "t_ms" => 42_000, "visibility" => "clear" },
                  { "t_ms" => 150_000, "visibility" => "partial" }, { "t_ms" => 150_000, "visibility" => "clear" }]
    )

    assert_equal %W[#{dir}0042.jpg #{dir}0230.jpg #{dir}0306.jpg #{dir}0500.jpg], p.reference_still_keys
    assert_equal "clear", p.still_visibility("#{dir}0230.jpg"), "the clearest sighting at that second wins"
    assert_equal "partial", p.still_visibility("#{dir}0306.jpg")
    assert_nil p.still_visibility("#{dir}0500.jpg")
  end
end
