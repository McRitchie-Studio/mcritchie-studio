# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require_relative "../support/tiktok_draft_fakes"

# [component] The clip card's slug (with its copy control) and its TikTok
# section: Draft to TikTok, on only with a primary version and TikTok keys;
# the latest attempt with its state, caption and Copy; earlier attempts folded.
# [integration] The button records an attempt and queues the upload; a
# refusal records nothing; Check TikTok re-reads a processing attempt; admin
# only. TikTok, R2 and ESPN are fakes; the people are synthetic.
class AltVideoClipTiktokDraftsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @video = TiledVideo.seed!
    person = Person.create!(athlete: true, first_name: "Test", last_name: "Tiktok Delta")
    look = person.appearances.live.create!(descriptor: "Home", team_slug: "buffalo-bills")
    @video.video_performers.find_by!(ordinal: 1).update!(recast_person_slug: person.slug, recast_appearance_slug: look.slug, recast_keep: false)
    @alt = AltVideo.build_from!(@video.reload)
    @clip = @alt.clips.first
    TiledVideo.version!(@clip, number: 1)
    @uploader = TiktokDraftFakes::Uploader.new
    Tiktok::DraftClip.uploader = @uploader
    Tiktok::DraftClip.reader = TiktokDraftFakes::Reader.new
    Tiktok::DraftClip.fetch = TiktokDraftFakes.espn
  end

  teardown { Tiktok::DraftClip.uploader = Tiktok::DraftClip.reader = Tiktok::DraftClip.fetch = nil }

  def card(ordinal) = "[data-test='alt-clip'][data-ordinal='#{ordinal}']"

  def page = get(music_video_alt_video_path(@video, @alt))

  def draft!(ordinal = 1) = post(music_video_alt_video_clip_tiktok_drafts_path(@video, @alt, ordinal))

  test "every card shows its clip's slug with a copy control" do
    log_in_as users(:alex)
    page

    @alt.clips.each do |clip|
      assert_select "#{card(clip.chunk_ordinal)} [data-test='clip-slug']", clip.slug
      assert_select "#{card(clip.chunk_ordinal)} [data-test='clip-slug-copy']", /Copy slug/
    end
  end

  test "Draft to TikTok is on for a clip with a primary version and off, with the reason, for one without" do
    log_in_as users(:alex)
    page

    assert_select "#{card(1)} [data-test='clip-tiktok'][data-enabled='true']" do
      assert_select "form[data-test='clip-tiktok-draft'] button:not([disabled])", /Draft to TikTok/
      assert_select "*", /Sends Version 1 to your TikTok drafts/
    end
    assert_select "#{card(2)} [data-test='clip-tiktok'][data-enabled='false']" do
      assert_select "form[data-test='clip-tiktok-draft'] button[disabled]"
      assert_select "[data-test='clip-tiktok-blocker']", /No generated version yet/
    end
  end

  test "without TikTok keys on the server the button is off and says so" do
    Tiktok::DraftClip.uploader = nil
    log_in_as users(:alex)
    page

    assert_select "#{card(1)} [data-test='clip-tiktok-blocker']", "TikTok keys are not set on this server."
    assert_select "#{card(1)} form[data-test='clip-tiktok-draft'] button[disabled]"
  end

  test "the button records an attempt and queues the upload; the card shows it with the caption" do
    log_in_as users(:alex)
    assert_enqueued_jobs(1, only: TiktokDraftJob) { draft! }

    draft = TiktokDraft.sole
    assert_redirected_to music_video_alt_video_path(@video, @alt, anchor: "clip-1")
    assert_equal [@clip.slug, 1, "queued", users(:alex).email], [draft.clip_slug, draft.version_number, draft.state, draft.requested_by]
    assert_match(/on its way to your TikTok drafts/, flash[:notice])

    perform_enqueued_jobs
    page
    assert_select "#{card(1)} [data-test='clip-tiktok-latest'][data-state='delivered']" do
      assert_select "[data-test='clip-tiktok-state']", "In your TikTok drafts"
      assert_select "[data-test='clip-tiktok-caption']", "Bills 3-2 #nfl #nfltiktok #footballtiktok #bills #fyp"
      assert_select "[data-test='clip-tiktok-copy']", /Copy caption/
      assert_select "[data-test='clip-tiktok-publish-id']", /v_inbox_file~synthetic\.1/
      assert_select "[data-test='clip-tiktok-team-rule']", /Test Tiktok Delta, the clip's target, by the look's team/
      assert_select "[data-test='clip-tiktok-check']", /no slogan hashtag/
    end
  end

  test "a failed attempt shows its error, and earlier attempts fold under the latest" do
    TiktokDraft.create!(clip: @clip, version_number: 1, version_object_key: "k1", caption: "c", state: "failed",
                        error: "TikTok refused chunk 1 of 1 (HTTP 400)", created_at: 2.hours.ago)
    TiktokDraft.create!(clip: @clip, version_number: 1, version_object_key: "k1", caption: "Bills 3-2", state: "processing",
                        publish_id: "v_inbox_file~p", facts: { "stand_in" => true })
    log_in_as users(:alex)
    page

    assert_select "#{card(1)} [data-test='clip-tiktok'][data-attempts='2']"
    assert_select "#{card(1)} [data-test='clip-tiktok-latest'][data-state='processing']" do
      assert_select "[data-test='clip-tiktok-refresh']"
      assert_select "[data-test='clip-tiktok-stand-in']", "stand-in"
    end
    assert_select "#{card(1)} [data-test='clip-tiktok-history'] [data-test='clip-tiktok-attempt'][data-state='failed']", /HTTP 400/
  end

  test "Check TikTok re-reads a processing attempt" do
    draft = TiktokDraft.create!(clip: @clip, version_number: 1, version_object_key: "k1", caption: "c", state: "processing",
                                publish_id: "v_inbox_file~p")
    log_in_as users(:alex)
    post refresh_music_video_alt_video_clip_tiktok_draft_path(@video, @alt, 1, draft)

    assert_equal ["delivered", "SEND_TO_USER_INBOX"], draft.reload.values_at(:state, :tiktok_status)
    assert_match(/In your TikTok drafts/, flash[:notice])
  end

  test "a refusal records nothing and says why" do
    log_in_as users(:alex)
    assert_no_enqueued_jobs { draft!(2) }

    assert_equal 0, TiktokDraft.count
    assert_match(/Clip 2 not drafted: Clip 2 has no generated version yet/, flash[:alert])
  end

  test "non-admins can draft nothing" do
    log_in_as users(:viewer)
    draft!

    assert_redirected_to root_path
    assert_equal 0, TiktokDraft.count
  end

  test "drafts cost no query per clip on the clip builder" do
    log_in_as users(:alex)
    count = lambda do
      queries = []
      ActiveSupport::Notifications.subscribed(->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" },
                                              "sql.active_record") { page }
      queries.size
    end
    bare = count.call
    @alt.clips.each { |c| TiktokDraft.create!(clip: c, version_number: 1, version_object_key: "k", caption: "c", state: "failed") }
    assert_equal bare, count.call
  end
end
