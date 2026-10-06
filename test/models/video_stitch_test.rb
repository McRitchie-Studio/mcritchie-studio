# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [unit] One stitch of an alt video: where it is filed, the primary versions
# it records, its states, and when it stops showing the alt video (stale).
class VideoStitchTest < ActiveSupport::TestCase
  setup do
    @video = TiledVideo.seed!
    @alt = AltVideo.build_from!(@video)
    @alt.clips.each { |clip| TiledVideo.version!(clip, number: 1, at: 1.hour.ago) }
    @stitch = MusicVideos::RequestStitch.new(@alt.reload).call.stitch
  end

  def clips = @alt.reload.clips.to_a

  def done!(stitch = @stitch)
    stitch.start!.finish!({ "duration_ms" => 72_000, "byte_size" => 4_096, "width" => 320, "height" => 180, "frame_rate" => "12",
                          "warnings" => ["chunk 4's take runs short"] })
  end

  test "a stitch is filed under the alt video's stitched folder and records each clip's primary version" do
    assert_equal "music_videos/test_artist_a/tiled_demo/alt_videos/01/stitched/tiled_demo_alt_01_stitched_01.mp4", @stitch.object_key
    assert_equal "Stitch 1", @stitch.name
    assert_equal "requested", @stitch.state
    assert_equal [[1, 0, 25_000, 1], [2, 20_000, 45_000, 1], [3, 40_000, 65_000, 1], [4, 60_000, 72_000, 1]],
                 @stitch.takes.map { |t| t.values_at("ordinal", "start_ms", "end_ms", "take") }
    assert_equal "1, 1, 1, 1", @stitch.take_list
    assert_equal [@stitch], @alt.stitches.to_a
    assert_equal [@video.slug, @alt.slug], [@stitch.music_video_slug, @stitch.alt_video_slug]
  end

  test "the request the stitcher reads resolves every version and the source to its object" do
    request = @stitch.as_request

    assert_equal [1, "requested", @stitch.object_key, TiledVideo::SOURCE, 72_000, @video.slug],
                 request.values_at("number", "state", "object_key", "source_object_key", "source_duration_ms", "music_video_slug")
    assert_equal 1, request["alt_video"]
    assert_equal clips.map { |c| c.primary_version.object_key }, request["takes"].map { |t| t["object_key"] }
    assert(request["takes"].all? { |t| t["object_key"].include?("/alt_videos/01/clips/") })
    assert_equal %w[end_ms object_key ordinal start_ms take], request["takes"].first.keys.sort
  end

  test "a key that does not name the stitch, a repeated number, or malformed takes are refused" do
    twin = @stitch.dup
    assert_not twin.valid?
    assert twin.errors.key?(:number)
    assert_raises(ActiveRecord::RecordNotUnique) { twin.save!(validate: false) }

    wrong = @stitch.dup.tap { |s| s.number = 5 }
    assert_not wrong.valid?
    assert_match(/must be .*alt_01_stitched_05\.mp4/, wrong.errors[:object_key].sole)

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

  test "a stitch is current until a clip's primary moves on" do
    done!
    assert_empty @stitch.stale_reasons(clips)
    assert_not @stitch.stale?
  end

  test "a newer version, an older version put back, and a regenerate flag each make it stale" do
    done!
    newer = TiledVideo.version!(clips.second, number: 2)
    assert_equal ["clip 2 is now on version 2 (stitched with version 1)"], @stitch.stale_reasons(clips)

    clips.second.versions.first.make_primary!
    assert_empty @stitch.stale_reasons(clips), "version 1 is back in front: the stitch shows the alt video again"
    newer.make_primary!

    clips.third.request_regenerate!("the jersey flickers")
    assert_equal ["clip 2 is now on version 2 (stitched with version 1)", "clip 3 is flagged for a regenerate"],
                 @stitch.stale_reasons(clips)
    assert @stitch.stale?
  end

  test "another alt video of the same source numbers its own stitches from 1" do
    other = AltVideo.build_from!(@video)
    other.clips.each { |clip| TiledVideo.version!(clip, number: 1) }
    stitch = MusicVideos::RequestStitch.new(other.reload).call.stitch

    assert_equal [1, 1], [@stitch.number, stitch.number]
    assert_includes stitch.object_key, "/alt_videos/02/stitched/tiled_demo_alt_02_stitched_01.mp4"
  end

  test "an alt video with stitches cannot be destroyed out from under them" do
    assert_raises(ActiveRecord::DeleteRestrictionError) { @alt.destroy! }
    assert_equal 1, VideoStitch.count
  end
end
