# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [integration] "Generate full video" on /music_videos/:slug: the admin gate,
# the button off until the video is ready to stitch, a request recorded and
# run by a job where this hub has ffmpeg or left waiting for bin/stitch-video
# where it has none, the finished stitch on the page with its player and
# download, and the stale mark once a chunk moves on.
class VideoStitchesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  Stitcher = MusicVideos::Stitcher

  setup do
    @video = TiledVideo.seed!
    @real_available = Stitcher.method(:available?)
    ffmpeg(false)
  end

  teardown { Stitcher.define_singleton_method(:available?, @real_available) }

  def ffmpeg(here) = Stitcher.define_singleton_method(:available?) { |**| here }

  def take_all! = @video.video_chunks.each { |chunk| TiledVideo.take!(chunk, number: 1, at: 1.hour.ago) }

  def chunk(ordinal) = @video.reload.video_chunks.find { |c| c.ordinal == ordinal }

  def generate = post(music_video_stitches_path(@video))

  def finish!(stitch)
    stitch.start!.finish!({ "duration_ms" => 72_000, "byte_size" => 3_500_000, "width" => 320, "height" => 180, "frame_rate" => "12",
                            "warnings" => ["chunk 4's take runs 11.5 s for a 12.0 s window: its last frame is held for 500 ms"] })
  end

  def panel = css_select("[data-test='full-video']").sole

  test "non-admins can request and read nothing" do
    take_all!
    log_in_as users(:viewer)

    generate
    assert_redirected_to root_path
    get music_video_stitch_path(@video, 1)
    assert_redirected_to root_path
    assert_equal 0, VideoStitch.count
  end

  test "the button is off, with the reason, until every chunk has a take" do
    log_in_as users(:alex)
    get music_video_path(@video)

    assert_select "[data-test='full-video'][data-ready='false']" do
      assert_select "form[data-test='full-video-form'] button[disabled]", "Generate full video"
      assert_select "[data-test='full-video-blocker']", /Not yet: Chunk 1, Chunk 2, Chunk 3, and Chunk 4 have no generated take\./
      assert_select "[data-test='full-video-none']", "No stitched video yet."
    end

    generate
    assert_redirected_to music_video_path(@video, anchor: "full-video")
    assert_match(/Not ready to stitch: Chunk 1, .* have no generated take\./, flash[:alert])
    assert_equal 0, VideoStitch.count
  end

  test "a flagged chunk turns the button off again" do
    take_all!
    chunk(3).request_regenerate!
    log_in_as users(:alex)
    get music_video_path(@video)

    assert_select "form[data-test='full-video-form'] button[disabled]"
    assert_select "[data-test='full-video-blocker']", /Chunk 3 is flagged for a regenerate/
  end

  test "ready: the button is on, and with no ffmpeg here the request waits for the bin" do
    take_all!
    log_in_as users(:alex)
    get music_video_path(@video)
    assert_select "[data-test='full-video'][data-ready='true'] form[data-test='full-video-form'][action=?] button:not([disabled])",
                  music_video_stitches_path(@video)

    assert_no_enqueued_jobs(only: StitchVideoJob) { generate }
    assert_redirected_to music_video_path(@video, anchor: "full-video")
    assert_equal "Stitch 1 requested: waiting for bin/stitch-video #{@video.slug} on the Mac.", flash[:notice]
    stitch = @video.stitches.sole
    assert_equal ["requested", "1, 1, 1, 1"], [stitch.state, stitch.take_list]

    follow_redirect!
    assert_select "[data-test='full-video-open'][data-number='1'][data-state='requested'][x-data='stitchProgress()'][data-status-url=?]",
                  music_video_stitch_path(@video, 1), /Stitch 1\s+is waiting for\s+bin\/stitch-video #{@video.slug}\s+on the Mac \(takes 1, 1, 1, 1\)\.\s+This server has no ffmpeg/
    assert_select "form[data-test='full-video-form'] button[disabled]", 1, "the same takes are already waiting"

    generate
    assert_equal "Stitch 1 is already waiting.", flash[:notice]
    assert_equal 1, @video.stitches.count
  end

  test "where this hub has ffmpeg the request is run by a job at once" do
    take_all!
    ffmpeg(true)
    log_in_as users(:alex)

    assert_enqueued_with(job: StitchVideoJob, args: [@video.slug, 1]) { generate }
    assert_equal "Stitch 1 requested: stitching now.", flash[:notice]

    follow_redirect!
    assert_select "[data-test='full-video-open'][data-state='requested']", /Stitch 1\s+is queued on this hub \(takes 1, 1, 1, 1\)/
    @video.stitches.sole.start!
    get music_video_path(@video)
    assert_select "[data-test='full-video-open'][data-state='running']", /Stitch 1\s+is stitching now/

    generate
    assert_equal "Stitch 1 is already running.", flash[:notice]
  end

  test "the progress poll answers the stitch's state" do
    take_all!
    log_in_as users(:alex)
    generate
    get music_video_stitch_path(@video, 1)
    assert_equal({ "number" => 1, "state" => "requested" }, response.parsed_body)

    finish!(@video.stitches.sole)
    get music_video_stitch_path(@video, 1)
    assert_equal "done", response.parsed_body["state"]
    get music_video_stitch_path(@video, 7)
    assert_response :not_found
  end

  test "a finished stitch shows with its player, facts and download, marked current" do
    take_all!
    log_in_as users(:alex)
    generate
    finish!(@video.stitches.sole)
    get music_video_path(@video)

    key = "music_videos/test_artist_a/tiled_demo/stitched/tiled_demo_stitched_01.mp4"
    assert_select "[data-test='full-video'][data-latest='1'][data-state='done']" do
      assert_select "[data-test='full-video-latest'][data-number='1'][data-stale='false']" do
        assert_select "[data-test='full-video-current']", "Current"
        assert_select "[data-test='full-video-stale']", 0
        assert_select "video[data-test='full-video-player'][controls][data-key=?]", key
        assert_select "video[data-test='full-video-player'][src*=?]", "stitched/tiled_demo_stitched_01.mp4"
        assert_select "[data-test='full-video-facts']", /72\.00 s · 320×180 · 12 fps · 3\.3 MB/
        assert_select "a[data-test='full-video-download'][download='tiled_demo_stitched_01.mp4'][href*='response-content-disposition=attachment']",
                      "Download stitch 1"
        assert_select "[data-test='full-video-takes']", /Takes 1, 1, 1, 1/
        assert_select "[data-test='full-video-notes'] li", /Note: chunk 4's take runs 11\.5 s .* held for 500 ms\./
      end
      assert_select "[data-test='full-video-open']", 0
      assert_select "form[data-test='full-video-form'] button:not([disabled])", 1, "another stitch may be made"
    end
  end

  test "a later take marks the stitch stale, and a new one replaces it on the page while both are kept" do
    take_all!
    log_in_as users(:alex)
    generate
    finish!(@video.stitches.sole)
    TiledVideo.take!(chunk(2), number: 2)
    get music_video_path(@video)

    assert_select "[data-test='full-video-latest'][data-stale='true']" do
      assert_select "[data-test='full-video-stale']", "Stale"
      assert_select "[data-test='full-video-stale-why']", /chunk 2 is now on take 2 \(stitched with take 1\)\. Generate again/
      assert_select "video[data-test='full-video-player']", 1, "the stale stitch still plays"
    end

    generate
    assert_equal 2, @video.stitches.reload.last.number
    finish!(@video.stitches.last)
    get music_video_path(@video)
    assert_select "[data-test='full-video-latest'][data-number='2'][data-stale='false'] [data-test='full-video-takes']", /Takes 1, 2, 1, 1/
    assert_select "[data-test='full-video-history'] [data-test='full-video-earlier'][data-number='1'][data-state='done']" do
      assert_select "a[href*='tiled_demo_stitched_01.mp4']", "Download"
    end
  end

  test "a regenerate flag marks the stitch stale too" do
    take_all!
    log_in_as users(:alex)
    generate
    finish!(@video.stitches.sole)
    chunk(4).request_regenerate!("the last second freezes")
    get music_video_path(@video)

    assert_select "[data-test='full-video-latest'][data-stale='true'] [data-test='full-video-stale-why']", /chunk 4 is flagged for a regenerate/
    assert_select "form[data-test='full-video-form'] button[disabled]"
  end

  test "a failed stitch says why, and generating again takes the next number" do
    take_all!
    log_in_as users(:alex)
    generate
    @video.stitches.sole.fail!("ffmpeg failed: Error: boom")
    get music_video_path(@video)

    assert_select "[data-test='full-video-failed']", /Stitch 1 failed:\s+ffmpeg failed: Error: boom\./
    assert_select "form[data-test='full-video-form'] button:not([disabled])"
    generate
    assert_equal [1, 2], @video.stitches.reload.map(&:number)
  end

  test "a run with no answer for half an hour can be replaced from the page" do
    take_all!
    log_in_as users(:alex)
    generate
    @video.stitches.sole.start!(at: 40.minutes.ago)
    get music_video_path(@video)

    assert_select "[data-test='full-video-open']", /has been running since .* with no answer/
    assert_select "form[data-test='full-video-form'] button:not([disabled])"
    generate
    assert_equal %w[failed requested], @video.stitches.reload.map(&:state)
  end

  test "the page costs the same queries however many stitches there are" do
    take_all!
    log_in_as users(:alex)
    generate
    finish!(@video.stitches.sole)
    one = count_queries { get music_video_path(@video) }
    3.times do
      TiledVideo.take!(chunk(1), number: chunk(1).takes.size + 1)
      generate
      finish!(@video.stitches.reload.last)
    end
    four = count_queries { get music_video_path(@video) }

    assert_equal one, four
  end

  private

  def count_queries
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
