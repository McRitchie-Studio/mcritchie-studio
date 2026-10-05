# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [unit] One stitch of a tiled video: where it is filed, the takes it records,
# its states, and when it stops showing the video as it stands (stale).
class VideoStitchTest < ActiveSupport::TestCase
  setup do
    @video = TiledVideo.seed!
    @video.video_chunks.each { |chunk| TiledVideo.take!(chunk, number: 1, at: 1.hour.ago) }
    @stitch = MusicVideos::RequestStitch.new(@video.reload).call.stitch
  end

  def chunks = @video.reload.video_chunks.to_a

  def done!(stitch = @stitch)
    stitch.start!.finish!({ "duration_ms" => 72_000, "byte_size" => 4_096, "width" => 320, "height" => 180, "frame_rate" => "12",
                          "warnings" => ["chunk 4's take runs short"] })
  end

  test "a stitch is filed under the video's stitched folder and records each chunk's take" do
    assert_equal "music_videos/test_artist_a/tiled_demo/stitched/tiled_demo_stitched_01.mp4", @stitch.object_key
    assert_equal "Stitch 1", @stitch.name
    assert_equal "requested", @stitch.state
    assert_equal [[1, 0, 25_000, 1], [2, 20_000, 45_000, 1], [3, 40_000, 65_000, 1], [4, 60_000, 72_000, 1]],
                 @stitch.takes.map { |t| t.values_at("ordinal", "start_ms", "end_ms", "take") }
    assert_equal "1, 1, 1, 1", @stitch.take_list
    assert_equal [@stitch], @video.stitches.to_a
  end

  test "the request the stitcher reads resolves every take and the source to its object" do
    request = @stitch.as_request

    assert_equal [1, "requested", @stitch.object_key, TiledVideo::SOURCE, 72_000, @video.slug],
                 request.values_at("number", "state", "object_key", "source_object_key", "source_duration_ms", "music_video_slug")
    assert_equal @video.chunk_takes.map(&:object_key), request["takes"].map { |t| t["object_key"] }
    assert_equal %w[end_ms object_key ordinal start_ms take], request["takes"].first.keys.sort
  end

  test "a key that does not name the stitch, a repeated number, or malformed takes are refused" do
    twin = @stitch.dup
    assert_not twin.valid?
    assert twin.errors.key?(:number)
    assert_raises(ActiveRecord::RecordNotUnique) { twin.save!(validate: false) }

    @stitch.object_key = @stitch.object_key.sub("stitched_01", "stitched_09")
    assert_not @stitch.valid?
    assert_match(/must be .*stitched_01\.mp4/, @stitch.errors[:object_key].sole)

    @stitch.reload
    [[], [{ "ordinal" => 1 }], @stitch.takes + [@stitch.takes.first], [@stitch.takes.first.merge("take" => 0)],
     [@stitch.takes.first.merge("note" => "x")]].each do |bad|
      @stitch.takes = bad
      assert_not @stitch.valid?, bad.inspect
      assert @stitch.errors.key?(:takes)
    end
  end

  test "requested, running, done: each step only from the one before" do
    assert_raises(VideoStitch::WrongState) { @stitch.finish!({ "duration_ms" => 1, "byte_size" => 1 }) }
    @stitch.start!
    assert_predicate @stitch, :running?
    assert_predicate @stitch, :open?
    assert_not_nil @stitch.started_at
    assert_raises(VideoStitch::WrongState) { @stitch.start! }

    done!(@stitch.tap { |s| s.update!(state: "requested") })
    assert_predicate @stitch.reload, :done?
    assert_not_predicate @stitch, :open?
    assert_equal [72_000, 4_096, 320, 180, "12", ["chunk 4's take runs short"]],
                 @stitch.attributes.values_at("duration_ms", "byte_size", "width", "height", "frame_rate", "warnings")
    assert_not_nil @stitch.finished_at
    assert_raises(VideoStitch::WrongState) { @stitch.start!(force: true) }
    assert_raises(VideoStitch::WrongState) { @stitch.fail!("late") }
    assert_predicate @stitch.reload, :done?
  end

  test "a failure keeps its reason, and force runs a failed or dead stitch again" do
    @stitch.start!
    @stitch.fail!("  ffmpeg failed:\n  boom  ")
    assert_predicate @stitch, :failed?
    assert_equal "ffmpeg failed: boom", @stitch.failure_reason
    assert_raises(VideoStitch::WrongState) { @stitch.start! }

    @stitch.start!(force: true)
    assert_predicate @stitch, :running?
    assert_nil @stitch.failure_reason
    @stitch.start!(force: true)
    assert_predicate @stitch, :running?

    @stitch.fail!(nil)
    assert_equal "no reason given", @stitch.failure_reason
    @stitch.start!(force: true)
    @stitch.fail!("x" * 900)
    assert_equal VideoStitch::REASON_MAX, @stitch.failure_reason.length
  end

  test "a done stitch must carry its length and size" do
    @stitch.start!
    assert_raises(ActiveRecord::RecordInvalid) { @stitch.finish!({ "duration_ms" => 0, "byte_size" => 10 }) }
    assert_predicate @stitch.reload, :running?
  end

  test "a run with no answer for half an hour is stuck" do
    @stitch.start!(at: 31.minutes.ago)
    assert_predicate @stitch, :stuck?
    @stitch.update!(started_at: 29.minutes.ago)
    assert_not_predicate @stitch, :stuck?
    assert_not_predicate VideoStitch.new(state: "requested"), :stuck?
  end

  test "a stitch is current until a chunk moves on" do
    done!
    assert_empty @stitch.stale_reasons(chunks)
    assert_not @stitch.stale?
  end

  test "a newer take, an older take put back, and a regenerate flag each make it stale" do
    done!
    newer = TiledVideo.take!(chunks.second, number: 2)
    assert_equal ["chunk 2 is now on take 2 (stitched with take 1)"], @stitch.stale_reasons(chunks)

    chunks.second.takes.first.make_current!
    assert_empty @stitch.stale_reasons(chunks), "take 1 is back in front: the stitch shows the video again"
    newer.make_current!

    chunks.third.request_regenerate!("the jersey flickers")
    assert_equal ["chunk 2 is now on take 2 (stitched with take 1)", "chunk 3 is flagged for a regenerate"], @stitch.stale_reasons(chunks)
    assert @stitch.stale?
  end

  test "a re-tile makes every earlier stitch stale" do
    done!
    MusicVideos::ReplaceClips.new(@video, TiledVideo.chunk_rows(@video, chunk_ms: 15_000, overlap_ms: 5_000),
                                  kind: "chunk", chunk_ms: 15_000, chunk_overlap_ms: 5_000).call

    assert_equal ["the video was re-tiled"], @stitch.stale_reasons(chunks)
  end

  test "destroying the video drops its stitches" do
    assert_difference -> { VideoStitch.count }, -1 do
      @video.destroy!
    end
  end
end
