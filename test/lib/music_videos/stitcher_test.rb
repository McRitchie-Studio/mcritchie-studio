# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../../../lib/music_videos/chunk_tiler"
require_relative "../../../lib/music_videos/stitch_plan"
require_relative "../../../lib/music_videos/stitcher"

# [unit] The stitcher against REAL ffmpeg: the plan's arguments are only right
# if ffmpeg agrees, so this renders small solid-colour takes of differing size,
# rate and length, stitches them, and reads the result back frame by frame. It
# needs ffmpeg and ffprobe and FAILS without them (CI installs ffmpeg for the
# rails job for this file); it never skips.
class MusicVideosStitcherRealTest < Minitest::Test
  Stitcher = MusicVideos::Stitcher

  # A folder standing in for the bucket.
  class DirStore
    attr_reader :puts

    def initialize(root)
      @root = root
      @puts = []
    end

    def get(key, path) = FileUtils.cp(File.join(@root, key), path)

    def put(key, path, content_type)
      @puts << [key, content_type]
      FileUtils.mkdir_p(File.dirname(File.join(@root, key)))
      FileUtils.cp(path, File.join(@root, key))
    end
  end

  def setup
    flunk "ffmpeg and ffprobe must be on PATH: this test stitches for real and does not skip" unless Stitcher.available?
    @dir = Dir.mktmpdir("stitcher-test")
    @bucket = File.join(@dir, "bucket")
    FileUtils.mkdir_p(@bucket)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def ffmpeg(*args)
    out, err, status = Open3.capture3("ffmpeg", "-v", "error", "-y", *args, binmode: true)
    assert status.success?, "ffmpeg #{args.join(' ')}: #{err}"
    out
  end

  # A 7 s source, 64x36 at 10 fps, grey, with a tone as its audio.
  def source!(audio: true)
    sound = audio ? ["-f", "lavfi", "-i", "sine=frequency=440:duration=7", "-c:a", "aac", "-b:a", "48k"] : []
    ffmpeg("-f", "lavfi", "-i", "color=c=gray:s=64x36:r=10:d=7", *sound, "-c:v", "libx264", "-pix_fmt", "yuv420p",
           File.join(@bucket, "source.mp4"))
  end

  # One solid-colour take, with a tone of its own that must never be heard.
  def take!(name, colour, size:, rate:, seconds:)
    ffmpeg("-f", "lavfi", "-i", "color=c=#{colour}:s=#{size}:r=#{rate}:d=#{seconds}",
           "-f", "lavfi", "-i", "sine=frequency=1200:duration=#{seconds}", "-c:v", "libx264", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-shortest", File.join(@bucket, name))
  end

  # 4 s chunks sharing 2 s: 0-4, 2-6, 4-7. At 10 fps: frames 0-40, 20-60, 40-70.
  def request
    takes = MusicVideos::ChunkTiler.windows(7_000, chunk_ms: 4_000, overlap_ms: 2_000).zip(%w[red.mp4 green.mp4 blue.mp4])
    { "object_key" => "stitched/demo_stitched_01.mp4", "source_object_key" => "source.mp4",
      "takes" => takes.map { |w, key| { "ordinal" => w.ordinal, "start_ms" => w.start_ms, "end_ms" => w.end_ms, "take" => 1, "object_key" => key } } }
  end

  def takes!
    take!("red.mp4", "red", size: "64x36", rate: 10, seconds: 4)
    take!("green.mp4", "0x00ff00", size: "32x18", rate: 20, seconds: 3.5) # smaller, faster, half a second short
    take!("blue.mp4", "blue", size: "64x36", rate: 10, seconds: 3.4)      # 0.4 s long
  end

  def stitch(store = DirStore.new(@bucket), out: StringIO.new)
    [Stitcher.new(out:).call(request, store:, dir: File.join(@dir, "work")), store, out]
  end

  # [r, g, b] of every frame, each frame averaged down to one pixel.
  def colours(path)
    ffmpeg("-i", path, "-vf", "scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-").bytes.each_slice(3).to_a
  end

  def stream(path, kind, entries)
    out, = Open3.capture2("ffprobe", "-v", "error", "-select_streams", kind, "-show_entries", "stream=#{entries}", "-of", "csv=p=0", path)
    out.strip.split(",")
  end

  def audio_md5(path) = ffmpeg("-i", path, "-map", "0:a:0", "-c", "copy", "-f", "md5", "-")

  def red?((r, g, b)) = r > 200 && g < 60 && b < 60
  def green?((r, g, b)) = g > 200 && r < 60 && b < 60
  def blue?((r, g, b)) = b > 200 && r < 60 && g < 60

  def test_the_stitch_is_h264_and_aac_at_the_target_and_exactly_the_planned_length
    source!
    takes!
    result, store, out = stitch

    assert_equal [["stitched/demo_stitched_01.mp4", "video/mp4"]], store.puts
    stored = File.join(@bucket, "stitched/demo_stitched_01.mp4")
    assert_equal %w[h264 64 36 10/1 70], stream(stored, "v:0", "codec_name,width,height,r_frame_rate,nb_frames")
    assert_equal ["aac"], stream(stored, "a:0", "codec_name")
    assert_equal [70, 70, 7000, 64, 36, "10"], [result.plan.total_frames, result.frames, result.duration_ms, result.width, result.height, result.frame_rate]
    assert_equal File.size(stored), result.byte_size
    assert_equal({ "duration_ms" => 7000, "byte_size" => result.byte_size, "width" => 64, "height" => 36, "frame_rate" => "10",
                   "warnings" => result.warnings }, result.report)
    assert_equal ["chunk 2's take runs 3.5 s for a 4.0 s window: its last frame is held for 500 ms",
                  "chunk 3's take runs 3.4 s for a 3.0 s window: its last 400 ms are trimmed"], result.warnings
    assert_includes out.string, "stitch plan: 3 takes -> 64x36 at 10 fps, 70 frames (7.000 s), audio copy"
    assert_includes out.string, "chunk 02  frames 20-60  stretch  fades in over 20 frames from frame 20"
  end

  def test_the_picture_crossfades_across_each_overlap_and_nowhere_else
    source!
    takes!
    result, = stitch
    frames = colours(result.path)

    assert_equal 70, frames.size
    assert frames[0..20].all? { |f| red?(f) }, "chunk 1 alone up to its overlap: #{frames[0..20].inspect}"
    assert green?(frames[40]), "chunk 2 alone where the two overlaps meet: #{frames[40].inspect}"
    assert frames[60..69].all? { |f| blue?(f) }, "chunk 3 alone after its overlap: #{frames[60..69].inspect}"

    # Inside the first overlap red falls and green rises, frame by frame, with no blue.
    first = frames[21..39]
    assert first.each_cons(2).all? { |a, b| b[0] <= a[0] && b[1] >= a[1] }, "red to green, monotone: #{first.inspect}"
    assert first.all? { |r, g, b| r < 250 && g > 5 && b < 60 }
    assert_in_delta frames[30][0], frames[30][1], 40, "half way through, an even mix: #{frames[30].inspect}"
    # And inside the second, green falls and blue rises.
    second = frames[41..59]
    assert second.each_cons(2).all? { |a, b| b[1] <= a[1] && b[2] >= a[2] }, "green to blue, monotone: #{second.inspect}"
    assert_in_delta frames[50][1], frames[50][2], 40, "half way through, an even mix: #{frames[50].inspect}"
  end

  def test_the_audio_is_the_sources_own_untouched_by_the_fades
    source!
    takes!
    result, = stitch

    assert_equal audio_md5(File.join(@bucket, "source.mp4")), audio_md5(result.path), "the source's audio packets, bit for bit"
    assert_equal stream(File.join(@bucket, "source.mp4"), "a:0", "duration,nb_frames"), stream(result.path, "a:0", "duration,nb_frames")
    assert_in_delta 7000, result.audio_ms, 50
    assert_equal 1, stream(result.path, "a", "index").size, "one audio stream: no take's audio came along"
  end

  def test_a_last_take_that_runs_short_holds_its_last_frame_to_the_end_of_the_video
    source!
    takes!
    take!("blue.mp4", "blue", size: "64x36", rate: 10, seconds: 2.5) # half a second short of its 3 s window
    result, = stitch
    frames = colours(result.path)

    assert_equal 70, frames.size, "the video still runs to the last chunk's end"
    assert frames[60..69].all? { |f| blue?(f) }, "held, not black: #{frames[60..69].inspect}"
    assert_includes result.warnings, "chunk 3's take runs 2.5 s for a 3.0 s window: its last frame is held for 500 ms"
  end

  def test_a_source_with_no_audio_stitches_silent
    source!(audio: false)
    takes!
    result, = stitch

    assert_nil result.audio_codec
    assert_equal 70, result.frames
    assert_includes result.warnings, "the source has no audio: the stitch is silent"
  end

  def test_a_dry_run_measures_and_plans_but_encodes_and_stores_nothing
    source!
    takes!
    store = DirStore.new(@bucket)
    plan = Stitcher.new(out: StringIO.new).call(request, store:, dir: File.join(@dir, "work"), dry_run: true)

    assert_kind_of MusicVideos::StitchPlan::Plan, plan
    assert_equal [[1, 0, 40], [2, 20, 60], [3, 40, 70]], plan.inputs.map { |i| [i.ordinal, i.start_frame, i.end_frame] }
    assert_equal Rational(10), plan.target.frame_rate, "the takes' best rate is 20, capped at the source's 10"
    assert_empty store.puts
    refute File.exist?(plan.arguments.last)
  end
end

# [unit] The stitcher's failure paths, with the shell faked: nothing is stored
# unless ffmpeg succeeded and the file is the planned length.
class MusicVideosStitcherFailureTest < Minitest::Test
  Stitcher = MusicVideos::Stitcher

  class Store
    attr_reader :puts

    def initialize = @puts = []
    def get(_key, path) = File.write(path, "mp4")
    def put(key, *_rest) = @puts << key
  end

  # ffprobe answers 1920x804 at 24 fps for every input; `output` is what it
  # answers for the stitched file; ffmpeg succeeds unless told not to.
  class Shell
    attr_reader :calls

    def initialize(ffmpeg_ok: true, output_frames: 1080, picture: true)
      @calls = []
      @ffmpeg_ok = ffmpeg_ok
      @output_frames = output_frames
      @picture = picture
    end

    def call(*cmd)
      @calls << cmd
      if cmd.first == "ffmpeg"
        File.write(cmd.last, "stitched") if @ffmpeg_ok
        return ["", "Conversion failed!\nError: boom at filter 3\n", @ffmpeg_ok]
      end

      stitched = cmd.last.include?("stitched")
      video = { "codec_type" => "video", "codec_name" => "h264", "width" => 1920, "height" => 804, "r_frame_rate" => "24/1",
                "avg_frame_rate" => "24/1", "nb_frames" => (stitched ? @output_frames : 600).to_s, "duration" => "25.0" }
      audio = { "codec_type" => "audio", "codec_name" => "aac", "duration" => "45.0" }
      [JSON.generate("streams" => (@picture || File.basename(cmd.last) == "a_b.mp4" ? [video, audio] : [audio]), "format" => { "duration" => "45.0" }), "", true]
    end
  end

  REQUEST = { "object_key" => "music_videos/a/b/stitched/b_stitched_02.mp4", "source_object_key" => "music_videos/a/b/source/a_b.mp4",
              "takes" => [{ "ordinal" => 1, "start_ms" => 0, "end_ms" => 25_000, "take" => 2, "object_key" => "generated/t1.mp4" },
                          { "ordinal" => 2, "start_ms" => 20_000, "end_ms" => 45_000, "take" => 1, "object_key" => "generated/t2.mp4" }] }.freeze

  def run_with(shell, request: REQUEST)
    store = Store.new
    Dir.mktmpdir("stitcher-failure") do |dir|
      error = assert_raises(Stitcher::Failure) { Stitcher.new(shell:, out: StringIO.new).call(request, store:, dir:) }
      return [error.message, store]
    end
  end

  def test_a_good_run_stores_the_stitch_once
    store = Store.new
    Dir.mktmpdir("stitcher-ok") do |dir|
      result = Stitcher.new(shell: Shell.new, out: StringIO.new).call(REQUEST, store:, dir:)
      assert_equal 1080, result.frames
    end
    assert_equal ["music_videos/a/b/stitched/b_stitched_02.mp4"], store.puts
  end

  def test_an_ffmpeg_failure_names_its_last_line_and_stores_nothing
    message, store = run_with(Shell.new(ffmpeg_ok: false))

    assert_equal "ffmpeg failed: Error: boom at filter 3", message
    assert_empty store.puts
  end

  def test_a_stitch_over_one_frame_per_chunk_off_the_plan_is_not_stored
    message, store = run_with(Shell.new(output_frames: 1083))
    assert_equal "the stitch came out 1083 frames long, not the planned 1080 (over one frame per chunk)", message
    assert_empty store.puts

    store = Store.new
    Dir.mktmpdir("stitcher-ok") { |dir| Stitcher.new(shell: Shell.new(output_frames: 1082), out: StringIO.new).call(REQUEST, store:, dir:) }
    assert_equal 1, store.puts.size, "two chunks: two frames off is inside one frame per chunk"
  end

  def test_a_take_with_no_picture_and_a_request_with_no_takes_are_refused
    message, = run_with(Shell.new(picture: false))
    assert_equal "chunk 1's take has no picture: t1.mp4", message

    message, = run_with(Shell.new, request: REQUEST.merge("takes" => []))
    assert_equal "the request names no takes", message
  end

  def test_a_plan_the_windows_cannot_make_is_a_failure_not_a_crash
    holed = REQUEST.merge("takes" => [REQUEST["takes"][0], REQUEST["takes"][1].merge("start_ms" => 26_000)])
    message, = run_with(Shell.new, request: holed)
    assert_equal "chunk 2 starts 1000 ms after chunk 1 ends: the tiling has a hole", message
  end

  def test_available_only_with_both_tools_on_the_path
    Dir.mktmpdir("tools") do |dir|
      refute Stitcher.available?(path: dir)
      File.write(File.join(dir, "ffmpeg"), "")
      File.chmod(0o755, File.join(dir, "ffmpeg"))
      refute Stitcher.available?(path: dir), "ffprobe is missing"
      File.write(File.join(dir, "ffprobe"), "")
      File.chmod(0o755, File.join(dir, "ffprobe"))
      assert Stitcher.available?(path: "/nowhere#{File::PATH_SEPARATOR}#{dir}")
    end
    refute Stitcher.available?(path: "")
  end

  def test_the_nominal_rate_is_used_unless_the_file_does_not_keep_to_it
    probe = lambda do |nominal, average|
      shell = ->(*_cmd) { [JSON.generate("streams" => [{ "codec_type" => "video", "width" => 2, "height" => 2, "r_frame_rate" => nominal, "avg_frame_rate" => average }], "format" => {}), "", true] }
      Stitcher.new(shell:, out: StringIO.new).probe("x.mp4")[:frame_rate]
    end

    assert_equal Rational(24_000, 1001), probe.call("24000/1001", "2997/125")
    assert_equal Rational(24), probe.call("24/1", "0/0")
    assert_equal Rational(2997, 100), probe.call("90000/1", "2997/100"), "a timebase, not a rate"
    assert_equal Rational(15), probe.call("30/1", "15/1"), "half its nominal rate: variable, take the average"
  end
end
