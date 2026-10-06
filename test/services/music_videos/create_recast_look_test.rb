# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/look_picker_video.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [unit] "Generate a new look" on a cast card, the record half: a named look
# for the athlete the operator chose, cast at once as the performer's recast
# (the card saves every pick; there is no Cast button). It starts no build and
# calls no generator. Every athlete here is synthetic.
class MusicVideosCreateRecastLookTest < ActiveSupport::TestCase
  setup do
    @video = LookPickerVideo.seed!
    @athlete = LookPickerVideo.athlete!
    @rookie = LookPickerVideo.rookie!
    @open = @video.video_performers.find_by!(ordinal: 1)
    @saved = @video.video_performers.find_by!(ordinal: 2)
  end

  def maker(performer, **attrs) = MusicVideos::CreateRecastLook.new(performer, **{ person_slug: @athlete.slug, descriptor: "Broncos blue" }.merge(attrs))

  test "a first look is made for a look-less athlete, becomes their default, and he is cast in it" do
    look = maker(@open, person_slug: @rookie.slug).call

    assert_equal [@rookie.slug, "Broncos blue"], [look.person_slug, look.descriptor]
    assert look.default?
    assert_nil look.sheet_build_state, "the record half starts no build"
    assert_equal [@rookie.slug, look.slug], @open.reload.values_at(:recast_person_slug, :recast_appearance_slug)
    assert @open.recast?
  end

  test "a new look for an athlete already cast is cast in place of the old one and is not the default" do
    look = maker(@saved, descriptor: "  Broncos   blue ").call

    assert_equal "Broncos blue", look.descriptor
    assert_not look.default?
    assert_equal look.slug, @saved.reload.recast_appearance_slug
    assert_includes Appearance.recastable.where(person_slug: @athlete.slug), look
  end

  test "generating for a different athlete than the one saved replaces him in the new look and drops the keep" do
    kept = @video.video_performers.find_by!(ordinal: 3)
    kept.update!(recast_keep: true)

    first = maker(@saved, person_slug: @rookie.slug).call
    second = maker(kept, person_slug: @rookie.slug, descriptor: "Road grey").call

    assert_equal [@rookie.slug, first.slug], @saved.reload.values_at(:recast_person_slug, :recast_appearance_slug)
    assert_equal [@rookie.slug, second.slug, false], kept.reload.values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
  end

  test "a reference photo is kept for a person with no stored headshot" do
    stranger = Person.create!(first_name: "Test", last_name: "Actor Eta")

    look = maker(@open, person_slug: stranger.slug, descriptor: "Navy suit", reference_url: " https://example.test/eta.jpg ").call

    assert_equal "https://example.test/eta.jpg", look.reference_url
    assert_nil maker(@open, descriptor: "No photo", reference_url: "  ").call.reference_url
  end

  test "the refusals: nobody chosen, no name, and a name that athlete already uses" do
    assert_equal "choose who replaces Person 1 first", maker(@open, person_slug: "").refusal
    assert_equal "choose who replaces Person 1 first", maker(@open, person_slug: "nobody-here").refusal
    assert_equal "name the look, for example its colours", maker(@open, descriptor: "   ").refusal
    assert_equal "Demo Winger Delta already has a look named Home Orange: choose it from the list", maker(@open, descriptor: "Home Orange").refusal
    assert_nil maker(@open, person_slug: @rookie.slug, descriptor: "Home Orange").refusal, "the name is free for another athlete"

    assert_no_difference -> { Appearance.count } do
      assert_raises(MusicVideos::CreateRecastLook::Refused) { maker(@open, descriptor: "Home Orange").call }
    end
    assert_nil @open.reload.recast_person_slug
  end

  test "a retired look frees its name" do
    @athlete.appearances.find_by!(descriptor: "Away White").update!(retired_at: Time.current)

    assert_nil maker(@open, descriptor: "Away White").refusal
  end

  test "a generated look rewrites the chunk prompts, for the athlete already cast or a new one" do
    video = RecastVideo.seed!
    alpha = RecastVideo.athlete!
    jacket = video.video_performers.find_by!(ordinal: 1)
    MusicVideos::RecastPerformer.new(jacket).call(person_slug: alpha.slug, appearance_slug: alpha.appearances.first.slug)
    named = video.reload.video_chunks.map(&:prompt)
    assert(named.any? { |prompt| prompt.include?("Test Athlete Alpha") })

    MusicVideos::CreateRecastLook.new(jacket, person_slug: alpha.slug, descriptor: "Alternate Black").call
    assert(video.reload.video_chunks.map(&:prompt).any? { |prompt| prompt.include?("like the Alternate Black model provided") })
    assert_not_equal named, video.video_chunks.map(&:prompt)

    MusicVideos::CreateRecastLook.new(jacket, person_slug: @rookie.slug, descriptor: "Road grey").call
    prompts = video.reload.video_chunks.map(&:prompt)
    assert(prompts.none? { |prompt| prompt.include?("Test Athlete Alpha") })
    assert(prompts.any? { |prompt| prompt.include?("Demo Novice Echo") })
  end
end
