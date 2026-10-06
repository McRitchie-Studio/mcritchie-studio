require "test_helper"
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [unit] A performer's recast: an athlete and one of that athlete's own live
# looks; no swap is the default (the legacy keep as is reads the same); only a
# swap waiting for its look is owed anything; naming an artist is optional, so
# a card with no artist and no swap is resolved and the cast confirms.
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

  test "keep is the swap turned off: alone it reads as no swap, with an athlete it is remembered, never a recast" do
    assert recast(recast_keep: true).valid?
    assert @performer.recast_decided?
    assert_not @performer.swap?
    assert_not @performer.swap_remembered?
    assert_nil @performer.recast_label

    assert recast(recast_keep: true, recast_person_slug: @athlete.slug, recast_appearance_slug: @home.slug).valid?
    assert @performer.swap_remembered?
    assert_not @performer.swap?
    assert_not @performer.recast?
    assert_not @performer.recast_pending?
    assert @performer.resolved?
    assert_nil @performer.swap_person
    assert_nil @performer.swap_look
  end

  test "an untouched performer is not swapped and owes nothing; only an athlete without a look is owed one" do
    assert @performer.recast_decided?
    assert_not @performer.swap?

    @performer.update!(recast_person_slug: @athlete.slug)
    assert @performer.swap?
    assert @performer.recast_pending?
    assert_not @performer.recast_decided?
    assert_not @performer.resolved?, "a swap waiting for its look is the one thing a card can owe"
    assert_equal "Test Athlete Alpha", @performer.recast_label
  end

  test "a look retired after the recast leaves the row saveable" do
    @performer.update!(recast_person_slug: @athlete.slug, recast_appearance_slug: @home.slug)
    @home.update!(retired_at: Time.current)

    assert @performer.reload.update(label: "man in the blue jacket")
  end

  test "a card with no artist and no swap counts as resolved, and the cast confirms with nothing pressed" do
    second = @video.video_performers.create!(ordinal: 2, label: "woman in the doorway")

    assert @performer.resolved?
    assert_not @performer.named?
    assert second.resolved?
    assert @video.reload.cast_ready?
    assert_nil @video.cast_blocker

    @video.confirm_cast!
    assert @video.reload.cast_confirmed?
    assert_nil @performer.reload.artist_slug
  end

  test "a cinematic video confirms the same way, and a swap waiting for its look does not hold the confirm" do
    @video.update!(kind: "cinematic")
    @performer.update!(recast_person_slug: @athlete.slug)

    assert_not @performer.resolved?
    assert @video.reload.cast_ready?, "the swap stays editable after the confirm"
    @video.confirm_cast!
    assert_equal "cast_confirmed", @video.reload.stage
  end

  test "naming is optional and kept: an artist names a card, an extra stays an extra" do
    Artist.create!(slug: "test-artist-a", name: "Test Artist A", kind: "person")
    @performer.update!(artist_slug: "test-artist-a")
    extra = @video.video_performers.create!(ordinal: 2, label: "woman in the doorway", extra: true)

    assert @performer.named?
    assert_not extra.named?
    assert extra.extra?
    assert [@performer, extra].all?(&:resolved?)
  end

  test "the video reads who is still owed a look" do
    second = @video.video_performers.create!(ordinal: 2, label: "woman in the doorway")
    assert_empty @video.reload.recast_open
    assert @video.recast_assigned?

    second.update!(recast_person_slug: @athlete.slug)
    assert_equal [2], @video.reload.recast_open.map(&:ordinal)
    assert_not @video.recast_assigned?

    second.update!(recast_appearance_slug: @home.slug)
    assert @video.reload.recast_assigned?
    assert_not MusicVideo.new.recast_assigned?
  end

  # The production row this change shipped onto (bigxthaplug-6wa, 2026-10-05),
  # rebuilt with synthetic people: a confirmed music video, Person 1 recast to
  # an athlete in a look, Persons 2-5 saved under the old "keep as is", no
  # artists named. It must read: Person 1 swapped, 2-5 not, cast still confirmed.
  test "a confirmed cast with one recast and four kept reads as one swap and four not" do
    others = (2..5).map { |n| @video.video_performers.create!(ordinal: n, label: "person #{n}", recast_keep: true) }
    @performer.update!(recast_person_slug: @athlete.slug, recast_appearance_slug: @home.slug)
    @video.update!(stage: "cast_confirmed")
    @video.reload

    assert @video.cast_confirmed?
    assert @performer.reload.swap?
    assert @performer.recast?
    others.each(&:reload).each do |p|
      assert_not p.swap?, "#{p.name} is not swapped"
      assert p.resolved?
      assert_not p.named?
    end
    assert_empty @video.recast_open
    assert @video.recast_assigned?
    assert_equal [1], @video.video_performers.select(&:swap?).map(&:ordinal)
    assert_equal "the cast is already confirmed", @video.cast_blocker
  end
end
