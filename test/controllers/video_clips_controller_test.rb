# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_clips.rb").to_s
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

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

  test "a clips-ready video keeps its cast confirmed while a name changes" do
    log_in_as users(:alex)
    decide(1, "approved")
    get music_video_path(@video)

    assert_select "[data-test='video-stage']", "Clips ready"
    assert_select "[data-test='cast-confirmed']"
    # Naming is optional and stays editable after the confirm; the stage does not move back.
    patch music_video_performer_path(@video, 2), params: { clear: "1" }
    assert_not @video.video_performers.find_by!(ordinal: 2).extra?
    assert_equal "clips_ready", @video.reload.stage, "the cast stays confirmed"
  end

  test "a video whose cast is not confirmed shows the clips locked" do
    log_in_as users(:alex)
    get music_video_path(NightCallCast.seed!)
    assert_select "[data-test='clips-locked']"
  end

  # [component] the chunk list on the page: in time order, apart from the
  # candidates, shrunk to its windows and the source's alt videos (piece 13:
  # each chunk's hand-off and generated versions live on the alt video page).
  test "a tiled video lists its chunks in time order, apart from the clip candidates" do
    video = TiledVideo.seed!
    log_in_as users(:alex)
    get music_video_path(video)

    assert_response :success
    assert_select "[data-test='video-kind']", "Cinematic video · Cast"
    assert_select "[data-test='clips-panel'] [data-test='clip-row']", 1
    assert_select "[data-test='clips-panel'] [data-test='chunk-window']", 0
    assert_select "[data-test='cast-panel'] [data-test='chunks-panel'] [data-test='clip-row']", 0
    assert_equal %w[1 2 3 4], css_select("[data-test='chunks-panel'] [data-test='chunk-window']").map { |row| row["data-ordinal"] }
    assert_equal ["0:00–0:25", "0:20–0:45", "0:40–1:05", "1:00–1:12"],
                 css_select("[data-test='chunk-window']").map { |w| w.text.strip[/\S+\z/] }
    assert_select "[data-test='chunks-count']", /4 chunks\s+· 0:00–1:12/
    assert_select "[data-test='chunks-tiling']", /25 s chunks on a 20 s stride, so each shares 5 s with the one before\./
    assert_select "[data-test='source-alt-videos'][data-count='0'] [data-test='alt-videos-index-link'][href='/alt_videos']"
    assert_select "[data-test='clips-approved-count']", /0 of 1/
  end

  test "the chunk list costs no query per chunk" do
    video = TiledVideo.seed!
    log_in_as users(:alex)
    count = ->(&block) { [].tap { |q| ActiveSupport::Notifications.subscribed(->(*, payload) { q << payload[:sql] unless payload[:name] == "SCHEMA" }, "sql.active_record", &block) }.size }
    four = count.call { get music_video_path(video) }

    video.video_chunks.destroy_all
    none = count.call { get music_video_path(video) }
    assert_select "[data-test='chunks-empty']", /bin\/find-clips test-artist-a-tiled-demo --tile/
    assert_equal none, four, "four chunks render with the same queries as none"
  end

  test "the page describes a 15 s tiling in its own numbers" do
    video = TiledVideo.seed!
    MusicVideos::ReplaceClips.new(video, TiledVideo.chunk_rows(video, chunk_ms: 15_000, overlap_ms: 5_000),
                                  kind: "chunk", chunk_ms: 15_000, chunk_overlap_ms: 5_000).call
    log_in_as users(:alex)
    get music_video_path(video)

    assert_select "[data-test='chunks-tiling']", /15 s chunks on a 10 s stride, so each shares 5 s with the one before\./
    assert_select "[data-test='chunk-window']", 7
    assert_select "[data-test='chunk-window'][data-ordinal='2']", /0:10–0:25/
  end

  test "a chunk cannot be approved: the decision route reaches candidates only" do
    video = TiledVideo.seed!
    log_in_as users(:alex)

    patch music_video_clip_path(video, 4), params: { status: "approved" }
    assert_response :not_found
    assert_equal %w[proposed], video.video_chunks.pluck(:status).uniq

    patch music_video_clip_path(video, 1), params: { status: "approved" }
    assert_equal "approved", video.clip_candidates.sole.status
    assert_equal "proposed", video.video_chunks.first.status, "chunk 1 shares the ordinal and is untouched"
  end

  test "a video with no chunks says how to tile it, cast confirmed or not" do
    log_in_as users(:alex)
    get music_video_path(@video)
    assert_select "[data-test='chunks-empty']", /bin\/find-clips steve-aoki-night-call-clips --tile/
    assert_select "[data-test='video-kind']", "Music video · Cast"

    get music_video_path(NightCallCast.seed!)
    assert_select "[data-test='chunks-empty']", /bin\/find-clips steve-aoki-night-call --tile/
    assert_select "[data-test='chunks-locked']", false, "chunks no longer wait for the cast"
  end

  # bin/digest-video cuts the chunks before anyone is cast: the page lists them
  # while the cast still waits, and Build Clips stays off until the confirm
  # (the hand-off and the prompt live on an alt video's clip cards).
  test "an unconfirmed video lists the chunks the digest cut, with Build Clips off" do
    video = NightCallCast.seed!
    video.update!(duration_ms: 30_000)
    rows = MusicVideos::ChunkTiler.windows(30_000).map do |w|
      { "ordinal" => w.ordinal, "start_ms" => w.start_ms, "end_ms" => w.end_ms, "cast_shape" => "unknown",
        "performer_ordinals" => [], "object_key" => MusicVideos::ObjectKeys.chunk(source_key: video.source_object_key, **w.to_h) }
    end
    MusicVideos::ReplaceClips.new(video, rows, kind: "chunk").call
    log_in_as users(:alex)
    get music_video_path(video)

    assert_response :success
    assert_select "[data-test='video-stage']", "Digested"
    assert_select "[data-test='chunk-window']", 2
    assert_select "[data-test='chunks-empty']", false
    assert_select "[data-test='build-clips-form'] button[disabled][title='Confirm the cast first']", "Build Clips"
  end
end
