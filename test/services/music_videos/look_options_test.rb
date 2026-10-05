# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/look_picker_video.rb").to_s

# [unit] The rows of a cast card's look dropdown: each recastable look with
# its newest character sheet as the image, the default mark, its own page and
# where its sheet build stands. Every athlete and sheet here is synthetic, and
# nothing is generated.
class MusicVideosLookOptionsTest < ActiveSupport::TestCase
  setup do
    @athlete = LookPickerVideo.athlete!
    @finished, @bare, @building = %w[Home\ Orange Away\ White Alternate\ Blue].map { |d| @athlete.appearances.find_by!(descriptor: d) }
  end

  def rows(*slugs) = MusicVideos::LookOptions.for(slugs.presence || [@athlete.slug])
  def row(look) = rows.fetch(@athlete.slug).find { |o| o.slug == look.slug }

  def sheet!(look, url, at: Time.current, retired: false)
    artifact = Artifact.create!(kind: "character_sheet", image_url: url, source: "test", created_at: at, retired_at: (at if retired))
    artifact.subjects.create!(person_slug: look.person_slug, appearance_slug: look.slug, ordinal: 1)
    artifact
  end

  def queries
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "each look is a row, oldest first: name, default mark, image, state and its own page" do
    assert_equal ["Home Orange", "Away White", "Alternate Blue"], rows.fetch(@athlete.slug).map(&:descriptor)
    assert_equal [true, false, false], rows.fetch(@athlete.slug).map(&:default)
    assert_equal %w[ready empty building], rows.fetch(@athlete.slug).map(&:state)

    finished = row(@finished)
    assert_equal LookPickerVideo.sheet_image("Home Orange"), finished.image_url
    assert_equal "/people/test-athlete-delta/models/#{@finished.slug}", finished.url
    assert_nil row(@bare).image_url, "a look with no sheet has no image: the card draws a placeholder"
    assert_equal %i[slug descriptor default image_url state error url], finished.to_h.keys
  end

  test "the default mark follows the person's default look" do
    @bare.make_default!

    assert_equal [false, true, false], rows.fetch(@athlete.slug).map(&:default)
  end

  test "the image is the newest live character sheet; a retired sheet and another kind are passed over" do
    sheet!(@bare, "https://example.test/old.png", at: 3.days.ago)
    sheet!(@bare, "https://example.test/new.png", at: 1.day.ago)
    sheet!(@bare, "https://example.test/retired.png", at: 1.hour.ago, retired: true)
    pair = Artifact.create!(kind: "pair", image_url: "https://example.test/pair.png", source: "test")
    pair.subjects.create!(person_slug: @athlete.slug, appearance_slug: @bare.slug, ordinal: 1)

    assert_equal "https://example.test/new.png", row(@bare).image_url
    assert_equal "ready", row(@bare).state
  end

  test "a look being rebuilt keeps its old image and reads building" do
    @finished.update!(sheet_build_state: "building", sheet_build_started_at: 10.seconds.ago)

    assert_equal "building", row(@finished).state
    assert_equal LookPickerVideo.sheet_image("Home Orange"), row(@finished).image_url
  end

  test "a failed build with no sheet reads failed and carries the reason; with a sheet it stays ready" do
    @bare.update!(sheet_build_state: "failed", sheet_build_error: "no cached headshot")
    @finished.update!(sheet_build_state: "failed", sheet_build_error: "the generator timed out")

    assert_equal ["failed", "no cached headshot"], [row(@bare).state, row(@bare).error]
    assert_equal ["ready", nil], [row(@finished).state, row(@finished).error]
  end

  test "a build that went stale is no longer building" do
    @building.update!(sheet_build_started_at: (Appearances::SheetBuild::STALE_AFTER + 1.minute).ago)

    assert_equal "empty", row(@building).state
  end

  test "a retired look and a music-video look are not rows" do
    @bare.update!(retired_at: Time.current)
    video = LookPickerVideo.video!
    Appearance.create!(person_slug: @athlete.slug, descriptor: "As seen in the video", music_video_slug: video.slug, performer_ordinal: 1)

    assert_equal ["Home Orange", "Alternate Blue"], rows.fetch(@athlete.slug).map(&:descriptor)
  end

  test "a person with no look has no key, and blank slugs ask nothing" do
    rookie = LookPickerVideo.rookie!

    assert_equal [@athlete.slug], rows(@athlete.slug, rookie.slug, nil, "").keys
    assert_equal({}, MusicVideos::LookOptions.for([]))
    assert_equal 0, queries { MusicVideos::LookOptions.for([nil, ""]) }
  end

  test "the query count does not grow with the people or the looks" do
    one = queries { rows(@athlete.slug) }
    other = LookPickerVideo.athlete_person!(first_name: "Test", last_name: "Athlete Zeta")
    4.times { |i| sheet!(other.appearances.create!(descriptor: "Look #{i}"), "https://example.test/#{i}.png") }

    assert_equal one, queries { rows(@athlete.slug, other.slug) }
    assert_operator one, :<=, 3
  end
end
