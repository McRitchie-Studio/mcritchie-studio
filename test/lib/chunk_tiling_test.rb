# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/chunk_tiling"

# [unit] The shared chunk tiler (bin/digest-video and bin/find-clips --tile)
# with ffmpeg, R2 and the hub API faked: it cuts the whole video, posts the
# set as kind "chunk", and a re-digest of a source that already has chunks
# cuts nothing unless told to replace them.
class ChunkTilingTest < Minitest::Test
  SOURCE_KEY = "music_videos/test_artist_a/tiled_demo/source/test_artist_a_tiled_demo.mp4"

  class FakeShell
    attr_reader :calls

    def initialize(duration: "72.000000") = (@calls = []) && (@duration = duration)

    def call(*cmd)
      @calls << cmd
      return ["#{@duration}\n", "", true] if cmd.first == "ffprobe"

      File.write(cmd.last, "chunk")
      ["", "", true]
    end
  end

  class FakeStorage
    attr_reader :puts

    def initialize = @puts = []

    def put(key, path, type) = @puts << [key, File.read(path), type]
  end

  class FakeApi
    attr_reader :posts

    def initialize = @posts = []

    def post(path, body)
      @posts << [path, body]
      {}
    end
  end

  def video(**extra)
    { "slug" => "test-artist-a-tiled-demo", "stage" => "digested", "duration_ms" => 72_000,
      "source_object_key" => SOURCE_KEY, "performers" => [], "chunks" => [] }.merge(extra.transform_keys(&:to_s))
  end

  def tiled(chunk_ms: 25_000, overlap_ms: 5_000, count: 4)
    video(chunks: (1..count).map { |n| { "ordinal" => n } }, chunk_ms:, chunk_overlap_ms: overlap_ms)
  end

  def run_tiler(video, shell: FakeShell.new, **opts)
    api = FakeApi.new
    storage = FakeStorage.new
    out = StringIO.new
    rows = Dir.mktmpdir do |dir|
      mp4 = File.join(dir, "source.mp4").tap { |p| File.write(p, "video") }
      ChunkTiling::Runner.new(api:, storage:, shell:, out:, **opts).call(video, mp4)
    end
    [rows, api, storage, shell, out.string]
  end

  def test_a_new_source_is_cut_whole_and_posted_as_chunks
    rows, api, storage, = run_tiler(video)

    assert_equal [[0, 25_000], [20_000, 45_000], [40_000, 65_000], [60_000, 72_000]], rows.map { |r| r.values_at(:start_ms, :end_ms) }
    assert_equal %w[unknown], rows.map { |r| r[:cast_shape] }.uniq, "an uncast source has nobody on screen yet"
    assert_equal [[]], rows.map { |r| r[:performer_ordinals] }.uniq
    assert_equal rows.map { |r| r[:object_key] }, storage.puts.map(&:first)
    assert_equal 1, api.posts.size
    path, body = api.posts.first
    assert_equal "/api/v1/music_videos/test-artist-a-tiled-demo/clips", path
    assert_equal({ kind: "chunk", chunk_ms: 25_000, chunk_overlap_ms: 5_000, clips: rows }, body)
  end

  # The re-digest rule: chunks on the record at this chunk length and overlap
  # are this tiling (the hub accepted them only as the whole tiling).
  def test_a_source_already_tiled_the_same_way_is_left_alone
    rows, api, storage, shell, out = run_tiler(tiled)

    assert_equal [], rows
    assert_empty api.posts
    assert_empty storage.puts
    assert_empty shell.calls, "not even probed"
    assert_match "already tiled at 25 s chunks with a 5 s overlap: kept its 4 chunks, cut nothing", out
  end

  def test_a_source_tiled_another_way_is_kept_and_told_how_to_replace
    rows, api, storage, _shell, out = run_tiler(tiled(chunk_ms: 15_000, overlap_ms: 5_000, count: 7))

    assert_equal [], rows
    assert_empty api.posts
    assert_empty storage.puts
    assert_match "is tiled at 15 s chunks with a 5 s overlap, not 25 s chunks with a 5 s overlap", out
    assert_match "pass --retile to replace them", out
  end

  def test_replace_cuts_again_over_chunks_already_there
    rows, api, storage, = run_tiler(tiled(chunk_ms: 15_000, overlap_ms: 5_000, count: 7), replace: true)

    assert_equal 4, rows.size
    assert_equal 4, storage.puts.size
    assert_equal [25_000], api.posts.map { |_p, b| b[:chunk_ms] }
  end

  def test_dry_run_plans_the_chunks_and_cuts_uploads_and_posts_nothing
    rows, api, storage, shell, out = run_tiler(video, dry_run: true)

    assert_equal 4, rows.size
    assert_empty api.posts
    assert_empty storage.puts
    assert_equal ["ffprobe"], shell.calls.map(&:first)
    assert_match "4 chunks for test-artist-a-tiled-demo (25 s on a 20 s stride) (dry run", out
  end

  def test_a_file_that_is_not_the_recorded_source_is_refused
    error = assert_raises(ChunkTiling::Failure) { run_tiler(video, shell: FakeShell.new(duration: "150.000000")) }
    assert_match "runs 150000 ms but test-artist-a-tiled-demo is recorded at 72000 ms", error.message
  end

  def test_an_impossible_tiling_is_named_before_any_call
    tiler = ChunkTiling::Runner.new(api: FakeApi.new, storage: FakeStorage.new, shell: FakeShell.new, out: StringIO.new,
                                    chunk_ms: 5_000, overlap_ms: 5_000)
    assert_match "must be shorter than the chunk", tiler.problem
  end
end
