# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [unit] Filing an uploaded MP4 as a clip's next numbered version: the number,
# the object key, what is refused before anything is touched, and what a new
# version does to the clip (primary, regenerate flag cleared).
class MusicVideos::StoreClipVersionTest < ActiveSupport::TestCase
  StoreTake = MusicVideos::StoreClipVersion

  setup do
    @video = TiledVideo.seed!
    @alt = AltVideo.build_from!(@video)
    @chunk = @alt.clips.second
    @stored = []
    stored = @stored
    @real_store = StoreTake.method(:store)
    StoreTake.define_singleton_method(:store) { |key:, body:| stored << [key, body.size] }
  end

  teardown { StoreTake.define_singleton_method(:store, @real_store) }

  def upload(name: "generated.mp4", fixture: "stitch_demo.mp4", type: "video/mp4")
    file = Tempfile.new(["take", File.extname(name)], binmode: true)
    file.write(file_fixture(fixture).binread)
    file.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: name, type:)
  end

  def chunk(ordinal = 2, alt = @alt) = alt.reload.clips.find { |c| c.chunk_ordinal == ordinal }

  test "the first upload is version 1, stored whole under the alt video's clips folder" do
    take = StoreTake.new(@chunk, upload).call

    assert_equal 1, take.number
    assert_equal "music_videos/test_artist_a/tiled_demo/alt_videos/01/clips/tiled_demo_alt_01_chunk_02_0020_0045_v01.mp4",
                 take.object_key
    assert_equal [[take.object_key, file_fixture("stitch_demo.mp4").size]], @stored
    assert_equal file_fixture("stitch_demo.mp4").size, take.byte_size
    assert_equal "generated.mp4", take.original_filename
    assert_equal take, chunk.primary_version
    assert_predicate take, :primary?
  end

  test "each upload takes the next number and its own key; nothing is overwritten" do
    3.times { StoreTake.new(chunk, upload).call }

    assert_equal [1, 2, 3], chunk.versions.map(&:number)
    assert_equal 3, @stored.map(&:first).uniq.size
    assert_equal 3, chunk.primary_version.number
  end

  test "clips number their versions apart, and so do two alt videos of one source" do
    StoreTake.new(chunk(1), upload).call
    take = StoreTake.new(chunk(2), upload).call
    other = AltVideo.build_from!(@video)
    theirs = StoreTake.new(chunk(2, other), upload).call

    assert_equal [1, 1], [take.number, theirs.number]
    assert_includes theirs.object_key, "/alt_videos/02/clips/tiled_demo_alt_02_chunk_02_0020_0045_v01.mp4"
    assert_equal [1], chunk(2).versions.map(&:number), "the other alt video's upload is not this clip's"
  end

  test "a new version becomes primary over an older one the operator had put back" do
    first = StoreTake.new(@chunk, upload).call
    StoreTake.new(chunk, upload).call
    first.make_primary!
    assert_equal 1, chunk.primary_version.number

    StoreTake.new(chunk, upload).call
    assert_equal 3, chunk.primary_version.number
    assert_equal [false, false, true], chunk.versions.map(&:primary?), "exactly one primary"
  end

  test "a new version clears the clip's regenerate request, and no other chunk's" do
    @chunk.request_regenerate!("the jersey flickers")
    chunk(3).request_regenerate!

    StoreTake.new(chunk, upload).call

    assert_not chunk.regenerate_requested?
    assert_nil chunk.regenerate_note
    assert chunk(3).regenerate_requested?
  end

  test "no file, a non-MP4, a renamed non-MP4 and an empty file are refused before the bucket" do
    { nil => /choose the generated MP4 first/, "" => /choose the generated MP4 first/,
      upload(name: "notes.txt", fixture: "notes.txt", type: "text/plain") => /not an MP4/,
      upload(name: "renamed.mp4", fixture: "notes.txt") => /not an MP4/,
      upload(name: "generated.mov") => /not an MP4/ }.each do |file, why|
      error = assert_raises(StoreTake::Refused) { StoreTake.new(@chunk, file).call }
      assert_match why, error.message
    end

    assert_empty @stored
    assert_equal 0, AltVideoClipVersion.count
  end

  test "a file over the limit is refused by size" do
    big = upload
    big.define_singleton_method(:size) { StoreTake::MAX_BYTES + 1 }
    assert_match(/over 100 MB/, assert_raises(StoreTake::Refused) { StoreTake.new(@chunk, big).call }.message)
    assert_empty @stored
  end

  test "a bucket failure records no version and keeps the regenerate request" do
    @chunk.request_regenerate!
    StoreTake.define_singleton_method(:store) { |**| raise StoreTake::StorageFailed, "object storage did not take it (AccessDenied)" }

    assert_raises(StoreTake::StorageFailed) { StoreTake.new(@chunk, upload).call }

    assert_equal 0, AltVideoClipVersion.count
    assert chunk.regenerate_requested?
  end

  test "the real seam turns an unconfigured bucket into StorageFailed" do
    StoreTake.define_singleton_method(:store, @real_store)
    Studio::S3.stub(:upload, ->(**) { raise Studio::S3::NotConfigured, "no prefix" }) do
      error = assert_raises(StoreTake::StorageFailed) { StoreTake.store(key: "music_videos/a/b/alt_videos/01/clips/x.mp4", body: StringIO.new("x")) }
      assert_match(/not configured/, error.message)
    end
  end
end
