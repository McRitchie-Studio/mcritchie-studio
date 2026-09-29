require "test_helper"
require Rails.root.join("db/seeds/data/night_call_looks.rb").to_s

# [unit] A look needs a confirmed cast and a performer the operator labelled with
# an individual artist. Artists are synthetic: only the operator maps a performer.
class MusicVideos::CreateLookTest < ActiveSupport::TestCase
  setup do
    @video = NightCallLooks.seed!
    @labelled = @video.video_performers.find_by!(ordinal: 2)
    @extra = @video.video_performers.find_by!(ordinal: 3)
  end

  test "makes one look for the labelled artist, linked to this video and performer" do
    look = MusicVideos::CreateLook.call(@labelled)

    assert_equal [@video.slug, 2], [look.music_video_slug, look.performer_ordinal]
    assert_equal "Night Call (looks demo) look", look.descriptor
    assert_equal @labelled.artist.reload.person_slug, look.person_slug
    assert_equal "Test Artist B", look.person.full_name
    assert_equal "Person 2 already has a look for this video", MusicVideos::CreateLook.new(@labelled).refusal
  end

  test "refuses a performer nobody labelled with an artist" do
    assert_equal "Person 3 is not labelled with an artist", MusicVideos::CreateLook.new(@extra).refusal
    assert_raises(MusicVideos::CreateLook::Refused) { MusicVideos::CreateLook.call(@extra) }
    assert_equal 0, @video.looks.count
  end

  test "refuses before the cast is confirmed" do
    @video.update!(stage: "digested")

    assert_equal "the cast is not confirmed yet", MusicVideos::CreateLook.new(@labelled.reload).refusal
  end

  test "refuses a group and a performer with no stills" do
    group = Artist.create!(slug: "test-group-z", name: "Test Group Z", kind: "group")
    @labelled.update_columns(artist_slug: group.slug)
    assert_match(/is a group/, MusicVideos::CreateLook.new(@labelled.reload).refusal)

    @labelled.update_columns(artist_slug: Artist.find_by!(name: "Test Artist A").slug, still_object_keys: [])
    assert_equal "Person 2 has no stills from this video", MusicVideos::CreateLook.new(@labelled.reload).refusal
  end

  test "never matches an existing person by name: a namesake gets a disambiguated new one" do
    namesake = Person.create!(first_name: "Test", last_name: "Artist B")

    look = MusicVideos::CreateLook.call(@labelled)

    assert_not_equal namesake.slug, look.person_slug
    assert_equal "test-artist-b-artist", look.person_slug
  end

  test "a one-word artist name becomes a person" do
    @labelled.artist.update!(name: "Testmono")

    assert_equal "Testmono Testmono", MusicVideos::CreateLook.call(@labelled).person.full_name
  end
end
