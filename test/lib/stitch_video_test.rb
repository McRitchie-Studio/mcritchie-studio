# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/stitch_video"

# [unit] The agent side of the final stitch (bin/stitch-video) with ffmpeg, R2
# and the hub API faked: it takes the waiting request or asks for one, reports
# start, finish and failure in order, uploads only a finished file, and a dry
# run changes nothing. The ffmpeg work itself is MusicVideos::Stitcher's,
# proven against real ffmpeg in test/lib/music_videos/stitcher_test.rb.
class StitchVideoTest < Minitest::Test
  SOURCE_KEY = "music_videos/test_artist_a/tiled_demo/source/test_artist_a_tiled_demo.mp4"
  SLUG = "test-artist-a-tiled-demo"
  BASE = "/api/v1/music_videos/#{SLUG}/stitches".freeze
  TAKES = [[1, 0, 25_000, 2], [2, 20_000, 45_000, 1]].map do |ordinal, start_ms, end_ms, take|
    { "ordinal" => ordinal, "start_ms" => start_ms, "end_ms" => end_ms, "take" => take }
  end.freeze

  def self.stitch(number, state, started_at: nil)
    { "number" => number, "state" => state, "started_at" => started_at, "source_object_key" => SOURCE_KEY,
      "object_key" => MusicVideos::ObjectKeys.stitched(source_key: SOURCE_KEY, number:),
      "takes" => TAKES.map do |t|
        t.merge("object_key" => MusicVideos::ObjectKeys.take(source_key: SOURCE_KEY, ordinal: t["ordinal"], start_ms: t["start_ms"],
                                                             end_ms: t["end_ms"], number: t["take"]))
      end }
  end

  # The hub API: remembers every call; a POST moves the one stitch it holds.
  class FakeApi
    attr_reader :calls

    def initialize(stitches: [], ready: true, blocker: nil, fail_on: nil)
      @stitches = stitches
      @ready = ready
      @blocker = blocker
      @fail_on = fail_on
      @calls = []
    end

    def get(path)
      @calls << [:get, path]
      { "stitches" => @stitches, "ready" => @ready, "blocker" => @blocker, "current_takes" => TAKES }
    end

    def show(slug)
      @calls << [:show, slug]
      { "slug" => slug, "source_object_key" => SOURCE_KEY }
    end

    def post(path, payload)
      @calls << [:post, path, payload]
      step = path.delete_prefix(BASE)
      raise DigestVideo::Failure, "API 409: WRONG_STATE refused" if @fail_on == step
      raise DigestVideo::Failure, "API 409: NOT_READY #{@blocker}" if step.empty? && !@ready
      return @stitches.first if step.empty? && %w[requested running].include?(@stitches.first&.fetch("state"))
      return (@stitches.unshift(StitchVideoTest.stitch(@stitches.size + 1, "requested")) && @stitches.first) if step.empty?

      @stitches.first.merge!("state" => { "start" => "running", "finish" => "done", "failed" => "failed" }.fetch(step.split("/").last))
    end
  end

  class FakeStorage
    attr_reader :puts, :gets

    def initialize
      @puts = []
      @gets = []
    end

    def get(key, path)
      @gets << key
      File.write(path, "mp4")
      path
    end

    def put(key, path, content_type) = @puts << [key, File.read(path), content_type]
  end

  # ffprobe answers one shape for every file; ffmpeg writes the output.
  class FakeShell
    attr_reader :calls

    def initialize(ffmpeg_ok: true)
      @calls = []
      @ffmpeg_ok = ffmpeg_ok
    end

    def call(*cmd)
      @calls << cmd
      if cmd.first == "ffmpeg"
        File.write(cmd.last, "stitched") if @ffmpeg_ok
        return ["", "Error: boom\n", @ffmpeg_ok]
      end

      stitched = cmd.last.include?("stitched")
      frames = stitched ? 1080 : 600
      length = stitched ? "45.0" : "25.0"
      [JSON.generate("streams" => [{ "codec_type" => "video", "codec_name" => "h264", "width" => 1484, "height" => 620,
                                     "r_frame_rate" => "24/1", "avg_frame_rate" => "24/1", "nb_frames" => frames.to_s, "duration" => length },
                                   { "codec_type" => "audio", "codec_name" => "aac", "duration" => "45.0" }],
                     "format" => { "duration" => "45.0" }), "", true]
    end
  end

  def run_bin(api:, shell: FakeShell.new, **options)
    storage = FakeStorage.new
    out = StringIO.new
    Dir.mktmpdir("stitch-video-test") do |workdir|
      runner = StitchVideo::Runner.new(api:, storage:, shell:, out:, workdir:, **options)
      begin
        result = runner.call(SLUG)
      rescue DigestVideo::Failure => e
        error = e
      end
      return { result:, error:, storage:, out: out.string, shell:, api: }
    end
  end

  def steps(api) = api.calls.select { |c| c.first == :post }.map { |_, path, payload| [path.delete_prefix(BASE), payload] }

  def test_it_runs_the_waiting_request_and_reports_start_then_finish
    api = FakeApi.new(stitches: [self.class.stitch(3, "requested")])
    run = run_bin(api:)

    assert_nil run[:error]
    assert_equal [SOURCE_KEY, "music_videos/test_artist_a/tiled_demo/generated/tiled_demo_chunk_01_0000_0025_take_02.mp4",
                  "music_videos/test_artist_a/tiled_demo/generated/tiled_demo_chunk_02_0020_0045_take_01.mp4"], run[:storage].gets
    assert_equal [["music_videos/test_artist_a/tiled_demo/stitched/tiled_demo_stitched_03.mp4", "stitched", "video/mp4"]], run[:storage].puts
    report = { "duration_ms" => 45_000, "byte_size" => 8, "width" => 1484, "height" => 620, "frame_rate" => "24", "warnings" => [] }
    assert_equal [["/3/start", { force: false }], ["/3/finish", report]], steps(api)
    assert_includes run[:out], "stitch 3 of #{SLUG}: takes 2, 1"
    assert_includes run[:out], "stitch plan: 2 takes -> 1484x620 at 24 fps, 1080 frames (45.000 s), audio copy"
    assert_match(%r{stitch 3 done: 45\.000 s, 1484x620 at 24 fps, 0\.0 MB, r2://mcritchie-studio-dev/music_videos/.*/tiled_demo_stitched_03\.mp4}, run[:out])
  end

  def test_with_none_waiting_it_asks_for_one
    api = FakeApi.new(stitches: [self.class.stitch(1, "done")])
    run = run_bin(api:)

    assert_nil run[:error]
    assert_equal ["", "/2/start", "/2/finish"], steps(api).map(&:first)
    assert_equal "music_videos/test_artist_a/tiled_demo/stitched/tiled_demo_stitched_02.mp4", run[:storage].puts.first.first
  end

  def test_a_video_that_is_not_ready_is_refused_before_anything_is_fetched
    api = FakeApi.new(ready: false, blocker: "Chunk 2 has no generated take")
    run = run_bin(api:)

    assert_equal "API 409: NOT_READY Chunk 2 has no generated take", run[:error].message
    assert_empty run[:storage].gets
    assert_empty run[:shell].calls
  end

  def test_a_stitch_already_running_is_left_alone_unless_forced
    api = FakeApi.new(stitches: [self.class.stitch(2, "running", started_at: "2026-10-05T12:00:00Z")])
    run = run_bin(api:)
    assert_equal "stitch 2 of #{SLUG} is already running (since 2026-10-05T12:00:00Z): pass --force if that run is dead", run[:error].message
    assert_empty run[:storage].puts
    assert_equal [""], steps(api).map(&:first), "it asked, was handed the running one, and stopped"

    api = FakeApi.new(stitches: [self.class.stitch(2, "running")])
    run = run_bin(api:, force: true)
    assert_nil run[:error]
    assert_equal [["/2/start", { force: true }], "/2/finish"], [steps(api).first, steps(api).last.first]
  end

  def test_an_ffmpeg_failure_is_reported_and_nothing_is_uploaded
    api = FakeApi.new(stitches: [self.class.stitch(1, "requested")])
    run = run_bin(api:, shell: FakeShell.new(ffmpeg_ok: false))

    assert_equal "ffmpeg failed: Error: boom", run[:error].message
    assert_equal [["/1/start", { force: false }], ["/1/failed", { reason: "ffmpeg failed: Error: boom" }]], steps(api)
    assert_empty run[:storage].puts
  end

  def test_a_refused_finish_surfaces_after_the_upload
    api = FakeApi.new(stitches: [self.class.stitch(1, "requested")], fail_on: "/1/finish")
    run = run_bin(api:)

    assert_equal "API 409: WRONG_STATE refused", run[:error].message
    assert_equal 1, run[:storage].puts.size, "the file is in the bucket; the record was superseded"
  end

  def test_a_dry_run_plans_the_waiting_request_and_changes_nothing
    api = FakeApi.new(stitches: [self.class.stitch(4, "requested")])
    run = run_bin(api:, dry_run: true)

    assert_nil run[:error]
    assert_empty steps(api)
    assert_empty run[:storage].puts
    assert(run[:shell].calls.none? { |cmd| cmd.first == "ffmpeg" })
    assert_includes run[:out], "stitch 4 of #{SLUG} (dry run: nothing started, encoded, uploaded or reported): takes 2, 1"
    assert_includes run[:out], "chunk 02  frames 480-1080  exact  fades in over 120 frames from frame 480"
  end

  def test_a_dry_run_with_none_waiting_plans_what_a_request_would_hold
    api = FakeApi.new(stitches: [self.class.stitch(1, "done")])
    run = run_bin(api:, dry_run: true)

    assert_nil run[:error]
    assert_empty steps(api)
    assert_includes run[:out], "stitch 2 of #{SLUG} (dry run"
    assert_equal 3, run[:storage].gets.size

    blocked = run_bin(api: FakeApi.new(ready: false, blocker: "Chunk 2 has no generated take"), dry_run: true)
    assert_equal "#{SLUG} is not ready to stitch: Chunk 2 has no generated take", blocked[:error].message
  end

  def test_the_source_on_disk_is_not_fetched
    api = FakeApi.new(stitches: [self.class.stitch(1, "requested")])
    Dir.mktmpdir("local-source") do |dir|
      local = File.join(dir, "local.mp4")
      File.write(local, "mp4")
      run = run_bin(api:, source: local)

      assert_nil run[:error]
      assert_equal 2, run[:storage].gets.size
      refute_includes run[:storage].gets, SOURCE_KEY
      assert_includes run[:shell].calls.find { |cmd| cmd.first == "ffmpeg" }, local
    end
  end
end
