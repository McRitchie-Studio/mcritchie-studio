# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_clips.rb").to_s

# [integration] The clips panel round trip: admin gate, the list under the
# cast, and Approve / Reject moving the video to clips_ready and back.
class VideoClipsControllerTest < ActionDispatch::IntegrationTest
  setup { @video = NightCallClips.seed! }

  def decide(ordinal, status) = patch music_video_clip_path(@video, ordinal), params: { status: }

  test "non-admins cannot approve" do
    log_in_as users(:viewer)
    decide(1, "approved")
    assert_redirected_to root_path
    assert_equal "proposed", @video.video_clips.first.status
  end

  test "the page lists the clips below the cast with signed previews" do
    log_in_as users(:alex)
    get music_video_path(@video)

    assert_response :success
    assert_select "[data-test='cast-panel'] [data-test='clips-panel'] [data-test='clip-row']", 2
    assert_select "[data-test='clip-row'][data-ordinal='1'][data-src*='night_call_clips_clip_01'][data-src*='X-Amz-Signature']"
    assert_select "[data-test='clips-approved-count']", /0 of 2/
  end

  test "approving one clip makes the video clips ready; rejecting it takes that back" do
    log_in_as users(:alex)

    decide(1, "approved")
    assert_redirected_to music_video_path(@video, anchor: "clip-1")
    assert_equal "Clip 1 approved.", flash[:notice]
    assert_equal "clips_ready", @video.reload.stage

    decide(2, "rejected")
    assert_equal "clips_ready", @video.reload.stage, "one approved clip is enough"

    decide(1, "rejected")
    assert_equal "cast_confirmed", @video.reload.stage
    assert_equal %w[rejected rejected], @video.video_clips.pluck(:status)
  end

  test "an unknown decision changes nothing" do
    log_in_as users(:alex)
    decide(1, "published")
    assert_equal "Clip 1 not updated: choose approve or reject.", flash[:alert]
    assert_equal "proposed", @video.video_clips.first.status
  end

  test "a clips-ready video keeps its cast locked and says so" do
    log_in_as users(:alex)
    decide(1, "approved")
    get music_video_path(@video)

    assert_select "[data-test='video-stage']", "Clips ready"
    assert_select "[data-test='cast-confirmed']"
    patch music_video_performer_path(@video, 2), params: { clear: "1" }
    assert @video.video_performers.find_by!(ordinal: 2).extra?, "the cast stays confirmed"
  end

  test "a video whose cast is not confirmed shows the clips locked" do
    log_in_as users(:alex)
    get music_video_path(NightCallCast.seed!)
    assert_select "[data-test='clips-locked']"
  end
end
