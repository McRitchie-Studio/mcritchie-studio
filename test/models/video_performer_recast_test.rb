require "test_helper"
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [unit] A performer's recast: an athlete and one of that athlete's own live
# looks, or keep as is, never both; what counts as answered; and how a
# cinematic card closes without an artist while a music video's does not.
# Every artist and athlete here is synthetic.
class VideoPerformerRecastTest < ActiveSupport::TestCase
  setup do
    @athlete = RecastVideo.athlete!
    @home, @away = @athlete.appearances.order(:created_at, :id).to_a
    @video = MusicVideo.create!(slug: "recast-unit", platform: "youtube", source_url: "https://www.youtube.com/watch?v=ru",
                                source_id: "ru", title: "Recast Unit", kind: "music_video",
                                source_object_key: "music_videos/test_artist/recast_unit/source/a.mp4")
    @performer = @video.video_performers.create!(ordinal: 1, label: "man in the red jacket")
  end

  def recast(**attrs) = @performer.tap { |p| p.assign_attributes(attrs) }

  test "an athlete and their own look are a recast, labelled athlete then look" do
    assert recast(recast_person_slug: @athlete.slug, recast_appearance_slug: @away.slug).valid?
    assert @performer.recast?
    assert @performer.recast_decided?
    assert_not @performer.recast_pending?
    assert_equal "Test Athlete Alpha > Away White", @performer.recast_label
  end

  test "a look must belong to the chosen athlete" do
    other = Person.create!(first_name: "Test", last_name: "Athlete Beta", athlete: true)
    theirs = other.appearances.create!(descriptor: "Road Grey")

    assert_not recast(recast_person_slug: @athlete.slug, recast_appearance_slug: theirs.slug).valid?
    assert_includes @performer.errors[:recast_appearance_slug], "is not a live look of that athlete"
  end

  test "a retired look, a video-capture look, a missing athlete and a look alone are refused" do
    @away.update!(retired_at: Time.current)
    assert_not recast(recast_person_slug: @athlete.slug, recast_appearance_slug: @away.slug).valid?

    capture = @athlete.appearances.create!(descriptor: "Recast Unit look", music_video_slug: @video.slug, performer_ordinal: 1)
    assert_not recast(recast_person_slug: @athlete.slug, recast_appearance_slug: capture.slug).valid?

    assert_not recast(recast_person_slug: "nobody-here", recast_appearance_slug: nil).valid?
    assert_not recast(recast_person_slug: nil, recast_appearance_slug: @home.slug).valid?
    assert_includes @performer.errors[:recast_appearance_slug], "needs the athlete it belongs to"
  end

  test "keep as is and a recast cannot both be set" do
    assert recast(recast_keep: true).valid?
    assert @performer.recast_decided?
    assert_nil @performer.recast_label

    assert_not recast(recast_keep: true, recast_person_slug: @athlete.slug, recast_appearance_slug: @home.slug).valid?
    assert_includes @performer.errors[:recast_keep], "cannot be set on a performer who is recast"
  end

  test "an untouched performer and an athlete without a look are not answered; an extra nobody recast is" do
    assert_not @performer.recast_decided?

    @performer.update!(recast_person_slug: @athlete.slug)
    assert @performer.recast_pending?
    assert_not @performer.recast_decided?
    assert_equal "Test Athlete Alpha", @performer.recast_label

    extra = @video.video_performers.create!(ordinal: 2, label: "woman in the doorway", extra: true)
    assert extra.recast_decided?
    extra.update!(recast_person_slug: @athlete.slug)
    assert_not extra.recast_decided?
  end

  test "a look retired after the recast leaves the row saveable" do
    @performer.update!(recast_person_slug: @athlete.slug, recast_appearance_slug: @home.slug)
    @home.update!(retired_at: Time.current)

    assert @performer.reload.update(label: "man in the blue jacket")
  end

  test "a music video card needs an artist or an extra: a recast does not close it" do
    @performer.update!(recast_person_slug: @athlete.slug, recast_appearance_slug: @home.slug)

    assert_not @performer.resolved?
    assert_not @video.cast_ready?
    assert_equal "Person 1 is neither an artist nor an extra", @video.cast_blocker
  end

  test "a cinematic card closes on a recast or keep as is, with no artist" do
    @video.update!(kind: "cinematic")
    second = @video.video_performers.create!(ordinal: 2, label: "woman in the doorway")
    assert_not @performer.resolved?
    assert_equal "Person 1 and Person 2 are neither recast, kept as is, an artist nor an extra", @video.cast_blocker

    @performer.update!(recast_person_slug: @athlete.slug, recast_appearance_slug: @home.slug)
    assert @performer.resolved?
    assert_not @video.reload.cast_ready?

    second.update!(recast_person_slug: @athlete.slug)
    assert_not second.resolved?, "an athlete with no look is not an answer"
    second.update!(recast_person_slug: nil, recast_keep: true)
    assert second.resolved?

    @video.reload.confirm_cast!
    assert_equal "cast_confirmed", @video.reload.stage
    assert_nil @performer.reload.artist_slug
  end

  test "the video reads who is still owed a recast answer" do
    second = @video.video_performers.create!(ordinal: 2, label: "woman in the doorway")
    assert_equal [1, 2], @video.reload.recast_open.map(&:ordinal)
    assert_not @video.recast_assigned?

    @performer.update!(recast_person_slug: @athlete.slug, recast_appearance_slug: @home.slug)
    assert_equal [2], @video.reload.recast_open.map(&:ordinal)

    second.update!(recast_keep: true)
    assert @video.reload.recast_assigned?
    assert_not MusicVideo.new.recast_assigned?
  end
end
