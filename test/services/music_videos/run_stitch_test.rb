# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [integration] A requested stitch run on the hub (the job's path), with the
# stitcher faked: the request it is handed, done with its measurements, a
# failure recorded with its reason, and a request that is no longer waiting
# left alone. The stitcher itself is proven against real ffmpeg in
# test/lib/music_videos/stitcher_test.rb.
class MusicVideos::RunStitchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  Report = Struct.new(:report)

  class FakeStitcher
    attr_reader :requests

    def initialize(outcome)
      @outcome = outcome
      @requests = []
    end

    def call(request, store:, dir:)
      @requests << request.merge("store" => store, "dir_exists" => File.directory?(dir))
      @outcome.respond_to?(:call) ? @outcome.call : @outcome
    end
  end

  GOOD = Report.new({ "duration_ms" => 72_000, "byte_size" => 2_000_000, "width" => 320, "height" => 180, "frame_rate" => "12",
                      "warnings" => ["chunk 4's take runs 11.5 s for a 12.0 s window: its last frame is held for 500 ms"] })

  setup do
    @video = TiledVideo.seed!
    @alt = AltVideo.build_from!(@video)
    @alt.clips.each { |clip| TiledVideo.version!(clip, number: 1, at: 1.hour.ago) }
    @stitch = MusicVideos::RequestStitch.new(@alt.reload).call.stitch
    @store = Object.new
  end

  def run_with(outcome)
    stitcher = FakeStitcher.new(outcome)
    MusicVideos::RunStitch.new(@stitch, store: @store, stitcher:).call
    stitcher
  end

  test "a good run hands the stitcher the request and records the result" do
    stitcher = run_with(GOOD)

    seen = stitcher.requests.sole
    assert_same @store, seen["store"]
    assert seen["dir_exists"]
    assert_equal @stitch.object_key, seen["object_key"]
    assert_equal TiledVideo::SOURCE, seen["source_object_key"]
    assert_equal @alt.clips.map { |c| c.primary_version.object_key }, seen["takes"].map { |t| t["object_key"] }
    assert_equal ["done", 72_000, 2_000_000, 320, 180, "12"],
                 @stitch.reload.attributes.values_at("state", "duration_ms", "byte_size", "width", "height", "frame_rate")
    assert_equal GOOD.report["warnings"], @stitch.warnings
    assert_operator @stitch.finished_at, :>=, @stitch.started_at
  end

  test "a stitcher failure is the stitch's reason, not an error log" do
    assert_no_difference -> { ErrorLog.count } do
      run_with(-> { raise MusicVideos::Stitcher::Failure, "ffmpeg failed: Error: boom" })
    end

    assert_equal ["failed", "ffmpeg failed: Error: boom"], @stitch.reload.attributes.values_at("state", "failure_reason")
  end

  test "an unexpected error fails the stitch and is logged" do
    assert_difference -> { ErrorLog.count }, 1 do
      run_with(-> { raise IOError, "disk full" })
    end

    assert_equal ["failed", "IOError: disk full"], @stitch.reload.attributes.values_at("state", "failure_reason")
  end

  test "a request that is no longer waiting is left alone" do
    @stitch.start!
    stitcher = run_with(GOOD)
    assert_empty stitcher.requests, "already running: the bin has it"
    assert_predicate @stitch.reload, :running?

    @stitch.fail!("superseded by stitch 2")
    assert_empty run_with(GOOD).requests
    assert_predicate @stitch.reload, :failed?
  end

  test "a run superseded while it worked does not come back as done" do
    stitch = @stitch
    run_with(-> { stitch.reload.fail!("superseded by stitch 2") && GOOD })

    assert_equal ["failed", "superseded by stitch 2"], @stitch.reload.attributes.values_at("state", "failure_reason")
  end

  test "the job runs the named stitch and shrugs at one that is gone" do
    ran = []
    real = MusicVideos::RunStitch.method(:new)
    MusicVideos::RunStitch.define_singleton_method(:new) { |stitch| ran << stitch.number && Struct.new(:call).new(nil) }
    StitchVideoJob.perform_now(@alt.slug, 1)
    StitchVideoJob.perform_now(@alt.slug, 99)
    StitchVideoJob.perform_now("no-such-video-alt-1", 1)

    assert_equal [1], ran
  ensure
    MusicVideos::RunStitch.define_singleton_method(:new, real)
  end
end
