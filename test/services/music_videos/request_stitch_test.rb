# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [unit] Requesting an alt video's full video: refused until every clip has a
# primary version and none is flagged; numbered per alt video, never
# overwritten; one open request at a time.
class MusicVideos::RequestStitchTest < ActiveSupport::TestCase
  Request = MusicVideos::RequestStitch

  setup do
    @video = TiledVideo.seed!
    @alt = AltVideo.build_from!(@video)
    @chunks = @alt.clips.to_a
  end

  def take_all! = @chunks.each { |clip| TiledVideo.version!(clip, number: 1, at: 1.hour.ago) }

  def request = Request.new(@alt.reload).call

  test "refused, with the blocker, until every clip has a version and none is flagged" do
    error = assert_raises(Request::Refused) { request }
    assert_equal "Clip 1, Clip 2, Clip 3, and Clip 4 have no generated version", error.message

    @chunks.first(3).each { |clip| TiledVideo.version!(clip, number: 1) }
    assert_equal "Clip 4 has no generated version", assert_raises(Request::Refused) { request }.message

    TiledVideo.version!(@chunks.last, number: 1)
    @chunks.second.request_regenerate!
    assert_equal "Clip 2 is flagged for a regenerate", assert_raises(Request::Refused) { request }.message
    assert_equal 0, VideoStitch.count

    @chunks.second.clear_regenerate!
    assert_predicate request, :created?
  end

  test "asking again for the same versions hands back the open request" do
    take_all!
    first = request
    again = request

    assert_predicate first, :created?
    assert_not_predicate again, :created?
    assert_equal first.stitch, again.stitch
    first.stitch.start!
    assert_equal first.stitch, request.stitch, "running counts as open too"
    assert_equal 1, @alt.stitches.count
  end

  test "different versions, or a run gone quiet, supersede the open request with the next number" do
    take_all!
    first = request.stitch
    TiledVideo.version!(@chunks.third, number: 2)
    second = request

    assert_predicate second, :created?
    assert_equal 2, second.stitch.number
    assert_equal "1, 1, 2, 1", second.stitch.take_list
    assert_equal ["failed", "superseded by stitch 2"], first.reload.attributes.values_at("state", "failure_reason")

    second.stitch.start!(at: 45.minutes.ago)
    third = request.stitch
    assert_equal 3, third.number
    assert_equal "superseded by stitch 3", second.stitch.reload.failure_reason
    assert_equal %w[failed failed requested], @alt.stitches.reload.map(&:state)
  end

  test "a finished or failed stitch is kept and the next request takes the next number" do
    take_all!
    first = request.stitch
    first.start!.finish!({ "duration_ms" => 72_000, "byte_size" => 9 })
    second = request.stitch
    second.fail!("the Mac slept")
    third = request.stitch

    assert_equal [1, 2, 3], [first, second, third].map(&:number)
    assert_equal %w[done failed requested], @alt.stitches.reload.map(&:state)
    assert_equal 3, @alt.stitches.map(&:object_key).uniq.size
  end
end
