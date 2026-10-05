# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [component] The Full video panel: the Generate button and its blocker, where
# an open request stands (waiting for the bin, queued here, running, stuck),
# the latest finished stitch with its player and download (or the unreachable
# state), the stale mark, a failure's reason, and the earlier stitches.
class MusicVideoFullVideoViewTest < ActionView::TestCase
  helper MusicVideosHelper

  setup do
    @video = TiledVideo.seed!
    @url = "https://signed.example/stitched.mp4?X-Amz-Signature=abc"
  end

  def chunks = @video.reload.video_chunks.to_a

  def take_all! = chunks.each { |chunk| TiledVideo.take!(chunk, number: 1, at: 1.hour.ago) }

  def request! = MusicVideos::RequestStitch.new(@video.reload).call.stitch

  def finish!(stitch, bytes: 3_500_000)
    stitch.start!.finish!({ "duration_ms" => 72_042, "byte_size" => bytes, "width" => 1484, "height" => 620, "frame_rate" => "24000/1001" })
  end

  def render_panel(here: false, reachable: true)
    stitches = @video.reload.stitches.to_a.reverse
    keys = stitches.select(&:done?).map(&:object_key)
    render partial: "music_videos/full_video",
           locals: { video: @video, chunks:, stitches:, here:, urls: reachable ? keys.index_with { @url } : {},
                     downloads: reachable ? keys.index_with { |k| "#{@url}&dl=#{File.basename(k)}" } : {} }
  end

  test "not ready: the button is off and the panel says which chunks hold it up" do
    TiledVideo.take!(chunks.first, number: 1)
    render_panel

    assert_select "#full-video[data-test='full-video'][data-ready='false'][data-latest=''][data-state='']" do
      assert_select "h3", "Full video"
      assert_select "form[data-test='full-video-form'][action=?][method='post']", music_video_stitches_path(@video) do
        assert_select "button[data-test='full-video-generate'][disabled]", "Generate full video"
      end
      assert_select "[data-test='full-video-blocker']", "Not yet: Chunk 2, Chunk 3, and Chunk 4 have no generated take."
      assert_select "[data-test='full-video-none']", "No stitched video yet."
      assert_select "[data-test='full-video-open'], [data-test='full-video-latest'], [data-test='full-video-history']", 0
    end
  end

  test "ready with nothing asked: the button is on and there is no blocker" do
    take_all!
    render_panel

    assert_select "[data-test='full-video'][data-ready='true'] button[data-test='full-video-generate']:not([disabled])"
    assert_select "[data-test='full-video-blocker']", 0
  end

  test "a waiting request names the command on a hub without ffmpeg and the queue on one with it" do
    take_all!
    request!
    render_panel(here: false)

    assert_select "[data-test='full-video-open'][data-number='1'][data-state='requested'][data-status-url=?]", music_video_stitch_path(@video, 1) do
      assert_select "span.font-mono", "bin/stitch-video #{@video.slug}"
      assert_select "[data-test='full-video-changed'][x-show='changed'] button", "Show it"
    end
    assert_select "[data-test='full-video-open']", /is waiting for.*on the Mac \(takes 1, 1, 1, 1\)\.\s+This server has no ffmpeg/m
    assert_select "button[data-test='full-video-generate'][disabled]"
    assert_select "[data-test='full-video-none']", 0

    render_panel(here: true)
    assert_select "[data-test='full-video-open']", /Stitch 1\s+is queued on this hub/
  end

  test "a running request says so, and one gone quiet offers the way out" do
    take_all!
    stitch = request!
    stitch.start!
    render_panel
    assert_select "[data-test='full-video-open'][data-state='running']", /Stitch 1\s+is stitching now \(takes 1, 1, 1, 1\)/
    assert_select "button[data-test='full-video-generate'][disabled]"

    stitch.update!(started_at: 45.minutes.ago)
    render_panel
    assert_select "[data-test='full-video-open']", /has been running since .* with no answer\.\s+Generate again to replace it/
    assert_select "[data-test='full-video-open'] span.font-mono", "bin/stitch-video #{@video.slug} --force"
    assert_select "button[data-test='full-video-generate']:not([disabled])"
  end

  test "a waiting request for other takes leaves the button on" do
    take_all!
    request!
    TiledVideo.take!(chunks.second, number: 2)
    render_panel

    assert_select "[data-test='full-video-open'][data-state='requested']", /takes 1, 1, 1, 1/
    assert_select "button[data-test='full-video-generate']:not([disabled])", 1, "the takes moved on: ask again"
  end

  test "the latest finished stitch plays, downloads and states its facts" do
    take_all!
    finish!(request!)
    render_panel

    assert_select "[data-test='full-video'][data-latest='1'][data-state='done'] [data-test='full-video-latest'][data-stale='false']" do
      assert_select "[data-test='full-video-current']", "Current"
      assert_select "video[data-test='full-video-player'][controls][playsinline][preload='metadata'][src=?]", @url
      assert_select "[data-test='full-video-facts']", /72\.04 s · 1484×620 · 24000\/1001 fps · 3\.3 MB/
      assert_select "a[data-test='full-video-download'][download='tiled_demo_stitched_01.mp4'][href=?]", "#{@url}&dl=tiled_demo_stitched_01.mp4"
      assert_select "[data-test='full-video-notes']", 0
    end
  end

  test "with the store unreachable the stitch names its file instead of a dead player" do
    take_all!
    finish!(request!)
    render_panel(reachable: false)

    assert_select "[data-test='full-video-unreachable']", "Stitched file not reachable: tiled_demo_stitched_01.mp4"
    assert_select "video, [data-test='full-video-download']", 0
  end

  test "stale: the mark and every reason, with the old stitch still on show" do
    take_all!
    finish!(request!)
    TiledVideo.take!(chunks.first, number: 2)
    chunks.last.request_regenerate!
    render_panel

    assert_select "[data-test='full-video-latest'][data-stale='true']" do
      assert_select "[data-test='full-video-stale']", "Stale"
      assert_select "[data-test='full-video-current']", 0
      assert_select "[data-test='full-video-stale-why']",
                    /Made before the video changed: chunk 1 is now on take 2 \(stitched with take 1\) and chunk 4 is flagged for a regenerate\./
      assert_select "video[data-test='full-video-player']"
    end
  end

  test "a failed newest request shows its reason above the last good stitch, and earlier ones are listed" do
    take_all!
    finish!(request!)
    TiledVideo.take!(chunks.third, number: 2)
    finish!(request!, bytes: 5_000_000)
    TiledVideo.take!(chunks.third, number: 3)
    request!.fail!("ffmpeg failed: <b>boom</b>")
    render_panel

    assert_select "[data-test='full-video-failed']", /Stitch 3 failed:\s+ffmpeg failed: <b>boom<\/b>\./
    assert_select "[data-test='full-video-failed'] b", 0, "the reason is escaped"
    assert_select "[data-test='full-video-latest'][data-number='2'][data-stale='true']"
    assert_select "[data-test='full-video-earlier']", 2
    assert_select "[data-test='full-video-earlier'][data-number='3'][data-state='failed']", /Stitch 3\s+· failed · takes 1, 1, 3, 1 · ffmpeg failed/
    assert_select "[data-test='full-video-earlier'][data-number='1'][data-state='done']" do
      assert_select "a[download='tiled_demo_stitched_01.mp4']", "Download"
    end
  end
end
