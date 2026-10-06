# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/look_picker_video.rb").to_s

# [integration] "Generate a new look" on a cast card, through the route: the
# admin gate on an action that spends, the look made and its character sheet
# started through the one existing build (Appearances::SheetBuild, in a job),
# the card's poll reading building then ready, and the refusals. NOTHING HERE
# REACHES A GENERATOR: the adapter and the image store are stubbed, and every
# athlete is synthetic.
class VideoPerformerRecastLooksControllerTest < ActionDispatch::IntegrationTest
  STORED_URL = "https://mcritchie-studio-dev.s3.us-east-2.amazonaws.com/character-sheets/demo-novice-echo/sheet.png"

  class FakeAdapter
    class << self
      attr_accessor :result
      def new(_row) = instance
      def instance = @instance ||= allocate
    end

    def generate_and_wait(**) = self.class.result
  end

  setup do
    ImageGeneration::Registry.reload!
    @video = LookPickerVideo.seed!
    @athlete = LookPickerVideo.athlete!
    @rookie = LookPickerVideo.rookie!
  end

  teardown { ImageGeneration::Registry.reload! }

  def generate(ordinal = 1, **params)
    post music_video_performer_recast_looks_path(@video, ordinal), params: { person_slug: @rookie.slug, descriptor: "Broncos blue" }.merge(params)
  end

  def performer(ordinal) = @video.video_performers.find_by!(ordinal:)
  def card(ordinal = 1, look: nil) = music_video_path(@video, look: look&.slug, anchor: "person-#{ordinal}")

  def looks_json(person)
    get recast_athlete_looks_path(person.slug, format: :json)
    assert_response :success
    JSON.parse(response.body)
  end

  # A configured generator whose paid call is a stub.
  def with_generator
    FakeAdapter.result = ImageGeneration::Result.new(image_urls: ["data:image/png;base64,QUJD"], seed: nil, request_id: "resp_1",
                                                     generator_key: "openai_gpt5_sheet", version: "gpt-5-2025-08-07@v1", billable_units: 7_629)
    ImageGeneration::Adapter.stub(:for, FakeAdapter) do
      Appearances::StoreGeneratedImage.stub(:call, STORED_URL) do
        with_env("OPENAI_API_KEY", "sk-test") { yield }
      end
    end
  end

  test "a visitor and a signed-in non-admin make no look and start no build" do
    with_generator do
      assert_no_difference -> { Appearance.count } do
        generate
        assert_response :redirect
        log_in_as users(:viewer)
        generate
        assert_redirected_to root_path
      end
      get recast_athlete_looks_path(@athlete.slug, format: :json)
      assert_response :forbidden
    end

    assert_no_enqueued_jobs only: SheetBuildJob
    assert_nil performer(1).recast_person_slug
  end

  test "an admin makes the look and one sheet build is enqueued; the request itself calls no generator" do
    log_in_as users(:alex)

    with_generator do
      FakeAdapter.stub(:instance, -> { flunk "the request must not call the generator" }) do
        assert_enqueued_jobs 1, only: SheetBuildJob do
          assert_difference -> { @rookie.appearances.count } => 1, -> { ErrorLog.count } => 0 do
            generate(number: "17")
          end
        end
      end
    end

    look = @rookie.appearances.sole
    assert_redirected_to card(look:)
    assert_match "Broncos blue made for Demo Novice Echo. Its character sheet is building", flash[:notice]
    assert look.sheet_building?
    assert_equal 0, Artifact.joins(:subjects).where(artifact_subjects: { appearance_slug: look.slug }).count
    assert_equal [look.slug, "17"], enqueued_jobs.sole["arguments"].values_at(0, 2), "the typed jersey number rides the job"
    assert_equal [@rookie.slug, look.slug], performer(1).values_at(:recast_person_slug, :recast_appearance_slug),
                 "the card saves every pick: the athlete is cast in the look just made"
  end

  test "the card's poll reads building, then ready with the sheet once the job has run, and the look can be cast" do
    log_in_as users(:alex)

    with_generator do
      generate
      look = @rookie.appearances.sole
      assert_equal [[look.slug, "Broncos blue", true, nil, "building"]],
                   looks_json(@rookie).map { |row| row.values_at("slug", "descriptor", "default", "image_url", "state") }

      perform_enqueued_jobs
      assert_equal [[STORED_URL, "ready", "/people/demo-novice-echo/models/#{look.slug}"]],
                   looks_json(@rookie).map { |row| row.values_at("image_url", "state", "url") }
      assert_includes Artifact.find_by!(generator: "openai_gpt5_sheet").prompt, "Broncos blue game uniform", "the look's name is the uniform the sheet is asked for"

      patch music_video_performer_recast_path(@video, 1), params: { person_slug: @rookie.slug, appearance_slug: look.slug }
      assert_equal "Demo Novice Echo > Broncos blue", performer(1).recast_label
    end
  end

  test "a look still building may be cast: a look needs no sheet to be chosen" do
    log_in_as users(:alex)

    with_generator { generate }
    look = @rookie.appearances.sole
    assert look.sheet_building?
    patch music_video_performer_recast_path(@video, 1), params: { person_slug: @rookie.slug, appearance_slug: look.slug }

    assert performer(1).recast?
    assert_match "is replaced by Demo Novice Echo > Broncos blue", flash[:notice]
  end

  test "the landed card is cast in the new look, building, beside the athlete's other looks" do
    log_in_as users(:alex)

    with_generator { generate(2, person_slug: @athlete.slug, descriptor: "Road Teal") }
    look = @athlete.appearances.find_by!(descriptor: "Road Teal")
    assert_redirected_to card(2, look:)
    follow_redirect!

    assert_select "[data-ordinal='2'] [data-test='performer-recast'][data-state='recast']" do
      assert_select "[data-test='performer-recast'][data-saved-look=?][data-fresh-look=?]", look.slug, look.slug
      picker = css_select("[data-ordinal='2'] [data-test='performer-recast']").first
      rows = JSON.parse(picker["data-athlete"])["looks"]
      assert_equal [["Home Orange", "ready"], ["Away White", "empty"], ["Alternate Blue", "building"], ["Road Teal", "building"]],
                   rows.map { |row| row.values_at("descriptor", "state") }
    end
  end

  test "with no generator configured the look is still made, no build starts, and the alert says nothing was spent" do
    log_in_as users(:alex)

    with_env("OPENAI_API_KEY", nil) do
      assert_no_enqueued_jobs only: SheetBuildJob do
        assert_difference -> { @rookie.appearances.count } => 1, -> { ErrorLog.count } => 0 do
          generate
        end
      end
    end

    look = @rookie.appearances.sole
    assert_redirected_to card(look:)
    assert_match(/Broncos blue was made for Demo Novice Echo, but its character sheet did not start: .*nothing was spent/, flash[:alert])
    assert_nil look.sheet_build_state
    assert_equal ["empty"], looks_json(@rookie).pluck("state")
  end

  test "a person with no headshot and no reference photo gets the look and the reason the sheet cannot start" do
    log_in_as users(:alex)
    stranger = Person.create!(first_name: "Test", last_name: "Actor Eta")

    with_generator do
      assert_no_enqueued_jobs(only: SheetBuildJob) { generate(person_slug: stranger.slug, descriptor: "Navy suit") }
    end

    assert_equal "Navy suit", stranger.appearances.sole.descriptor
    assert_match(/Navy suit was made for Test Actor Eta, but its character sheet did not start: Test Actor Eta cannot be built/, flash[:alert])
  end

  test "the refusals make nothing, start nothing and log nothing" do
    log_in_as users(:alex)

    with_generator do
      assert_no_difference [-> { Appearance.count }, -> { ErrorLog.count }] do
        generate(descriptor: " ")
        assert_equal "No look made: name the look, for example its colours.", flash[:alert]
        generate(person_slug: "")
        assert_equal "No look made: choose who replaces Person 1 first.", flash[:alert]
        generate(person_slug: @athlete.slug, descriptor: "Home Orange")
        assert_match "already has a look named Home Orange", flash[:alert]
        assert_redirected_to card
      end
      generate(9)
      assert_response :not_found
      post music_video_performer_recast_looks_path("no-such-video", 1), params: { person_slug: @rookie.slug, descriptor: "X" }
      assert_response :not_found
    end

    assert_no_enqueued_jobs only: SheetBuildJob
    assert_nil performer(1).recast_person_slug
  end

  test "a second press with the same name is refused, so one press buys one sheet" do
    log_in_as users(:alex)

    with_generator do
      generate
      assert_no_enqueued_jobs(only: SheetBuildJob) { generate }
    end

    assert_match "already has a look named Broncos blue", flash[:alert]
    assert_equal 1, @rookie.appearances.count
    assert_enqueued_jobs 1, only: SheetBuildJob
  end

  test "the typeahead rows carry each look's image, state and page for the dropdown" do
    log_in_as users(:alex)

    get search_recast_athletes_path(format: :json, q: "winger delta")

    row = JSON.parse(response.body).sole
    assert_equal ["demo-winger-delta", "3 looks"], row.values_at("slug", "hint")
    assert_equal [["Home Orange", true, "ready"], ["Away White", false, "empty"], ["Alternate Blue", false, "building"]],
                 row["looks"].map { |look| look.values_at("descriptor", "default", "state") }
    assert_equal LookPickerVideo.sheet_image("Home Orange"), row["looks"].first["image_url"]
    assert_match %r{\A/people/demo-winger-delta/models/look-}, row["looks"].first["url"]
  end
end
