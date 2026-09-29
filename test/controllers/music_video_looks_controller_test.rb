# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_looks.rb").to_s

# [integration] Looks on /music_videos/:slug: make a look for a labelled performer,
# then build its sheet. The generator adapter and the upload are stubbed; nothing
# is spent. Artists are synthetic: only the operator maps a performer to one.
class MusicVideoLooksControllerTest < ActionDispatch::IntegrationTest
  STORED_URL = "https://mcritchie-studio-dev.s3.us-east-2.amazonaws.com/character-sheets/x/sheet.png".freeze

  class FakeAdapter
    class << self
      attr_accessor :calls
    end

    def initialize(row) = @row = row

    def generate_and_wait(prompt:, reference_urls:, **)
      self.class.calls << { prompt:, reference_urls: }
      ImageGeneration::Result.new(image_urls: ["data:image/png;base64,QUJD"], seed: nil, request_id: "resp_1",
                                  generator_key: @row.key, version: @row.provenance_version, billable_units: 7_629)
    end
  end

  setup do
    ImageGeneration::Registry.reload!
    @video = NightCallLooks.seed!
    FakeAdapter.calls = []
  end

  def with_fake_generator(&)
    ImageGeneration::Adapter.stub(:for, FakeAdapter) do
      Appearances::StoreGeneratedImage.stub(:call, STORED_URL) { with_env("OPENAI_API_KEY", "sk-test", &) }
    end
  end

  def make_look(ordinal = 2) = post music_video_looks_path(@video), params: { ordinal: }

  test "admin only" do
    make_look
    assert_redirected_to "/login"
    log_in_as users(:viewer)
    make_look
    assert_equal 0, @video.looks.count
  end

  test "the page lists labelled performers without a look, then the look with its stills" do
    log_in_as users(:alex)
    get music_video_path(@video)
    assert_select "[data-test='look-candidate']", 2
    assert_select "[data-test='look-card']", 0

    make_look
    look = @video.looks.sole
    assert_redirected_to music_video_path(@video, anchor: "look-#{look.slug}")
    follow_redirect!
    assert_select "[data-test='look-candidate']", 1
    assert_select "[data-test='look-card'][data-ordinal='2'] [data-test='look-reference']", 2 do |refs|
      assert_match(/person_02_0042\.jpg/, refs.first["data-key"])
    end
  end

  test "making a look refuses an unlabelled performer and says why" do
    log_in_as users(:alex)
    make_look(3)

    assert_equal "No look made: Person 3 is not labelled with an artist.", flash[:alert]
    assert_equal 0, @video.looks.count
  end

  test "building the sheet sends the video stills, clearest first, and files the sheet on the look" do
    log_in_as users(:alex)
    make_look
    look = @video.looks.sole

    with_fake_generator { post sheet_music_video_look_path(@video, look) }

    assert_equal 1, FakeAdapter.calls.size
    urls = FakeAdapter.calls.first[:reference_urls]
    assert_equal 2, urls.size
    assert_match(%r{\Ahttps://fixture\.invalid/music_videos/steve_aoki/night_call/stills/person_02_0042\.jpg\?}, urls[0])
    assert_match(/person_02_0306\.jpg/, urls[1])
    assert_no_match(/football|jersey/i, FakeAdapter.calls.first[:prompt])
    sheet = Artifact.joins(:subjects).find_by!(artifact_subjects: { appearance_slug: look.slug })
    assert_equal [STORED_URL, "character_sheet"], [sheet.image_url, sheet.kind]
    assert_match(/built one character sheet/, flash[:notice])

    follow_redirect!
    assert_select "[data-test='look-card'] img[data-test='look-sheet-image'][src=?]", STORED_URL
  end

  test "building refuses before the cast is confirmed and calls no generator" do
    log_in_as users(:alex)
    make_look
    look = @video.looks.sole
    @video.update!(stage: "digested")

    with_fake_generator { post sheet_music_video_look_path(@video, look) }

    assert_equal "Not yet: the cast is not confirmed.", flash[:alert]
    assert_empty FakeAdapter.calls
    assert_equal 0, Artifact.count
  end
end
