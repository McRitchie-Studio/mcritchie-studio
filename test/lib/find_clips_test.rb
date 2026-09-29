# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/find_clips"

# [unit] The agent side of stage 5 (bin/find-clips) with ffmpeg, R2 and the
# hub API faked: it measures, cuts accurately, uploads to the snake_case tree
# and posts the set, and it never starts before the cast is confirmed.
class FindClipsTest < Minitest::Test
  SOURCE_KEY = "music_videos/steve_aoki/night_call/source/steve_aoki_night_call_feat_lil_yachty_migos.mp4"

  # 150 s: intro to 12 s, highs up at 40 s and down at 55 s, outro after 138 s.
  def self.level(band, i)
    t = i * 500
    return -30.0 unless t.between?(12_000, 137_999)

    base = { "low" => -12.0, "mid" => -14.0, "high" => -24.0, "full" => -8.0 }.fetch(band)
    base + (t.between?(40_000, 54_999) && band == "high" ? 6.0 : 0.0) + (i.even? ? 0.4 : -0.4)
  end

  class FakeShell
    attr_reader :calls

    def initialize = @calls = []

    def call(*cmd)
      @calls << cmd
      graph = cmd[cmd.index("-filter_complex") + 1] if cmd.include?("-filter_complex")
      return bands(graph) if graph
      return ["", "[silencedetect @ 0x1] silence_start: 140.2\n[silencedetect @ 0x1] silence_end: 150.0", true] if cmd.join(" ").include?("silencedetect")
      return ["", "[Parsed_showinfo_2 @ 0x1] n:0 pts:1 pts_time:40.6 \n[Parsed_showinfo_2 @ 0x1] n:1 pts:2 pts_time:64.7 ", true] if cmd.join(" ").include?("showinfo")

      File.write(cmd.last, "clip") # a cut
      ["", "", true]
    end

    private

    def bands(graph)
      graph.scan(/file=(\S+?)\/(low|mid|high|full)\.txt/).each do |dir, band|
        lines = (0...300).map { |i| "frame:#{i} pts:#{i * 8000}\nlavfi.astats.Overall.RMS_level=#{FindClipsTest.level(band, i)}\n" }
        File.write(File.join(dir, "#{band}.txt"), lines.join)
      end
      ["", "", true]
    end
  end

  class FakeStorage
    attr_reader :puts, :gets

    def initialize
      @puts = []
      @gets = []
    end

    def put(key, path, type) = @puts << [key, File.read(path), type]

    def get(key, path)
      @gets << key
      File.write(path, "video")
      path
    end
  end

  class FakeApi
    attr_reader :posts

    def initialize(video)
      @video = video
      @posts = []
    end

    def show(_slug) = @video

    def post(path, body)
      @posts << [path, body]
      { "stage" => @video["stage"] }
    end
  end

  def video(stage: "cast_confirmed")
    { "slug" => "steve-aoki-night-call", "stage" => stage, "source_id" => "Sa7GSJJ_lOo",
      "source_object_key" => SOURCE_KEY, "caption_timing" => { "cues" => [], "sections" => [] },
      "performers" => [{ "ordinal" => 1, "label" => "desk", "artist_slug" => "lil-yachty", "extra" => false,
                         "sightings" => [{ "t_ms" => 45_000, "visibility" => "clear" }] }] }
  end

  def run_finder(api:, storage: FakeStorage.new, shell: FakeShell.new, **opts)
    Dir.mktmpdir do |dir|
      source = File.join(dir, "local.mp4").tap { |p| File.write(p, "video") }
      runner = FindClips::Runner.new(api:, storage:, shell:, out: StringIO.new, workdir: dir,
                                     source: opts.delete(:no_source) ? nil : source, **opts)
      [runner.call("steve-aoki-night-call"), storage, shell]
    end
  end

  def test_cuts_uploads_and_posts_the_set
    api = FakeApi.new(video)
    rows, storage, shell = run_finder(api:)

    assert_equal 1, rows.size
    clip = rows.first
    assert_equal [40_600, 64_700, "chorus_to_verse", 55_000, "solo", 1, [1]],
                 clip.values_at(:start_ms, :end_ms, :seam, :seam_ms, :cast_shape, :target_performer, :performer_ordinals)
    key = "music_videos/steve_aoki/night_call/clips/night_call_clip_01_chorus_to_verse_solo_0040_0104.mp4"
    assert_equal key, clip[:object_key]
    assert_equal [[key, "clip", "video/mp4"]], storage.puts
    assert_equal [["/api/v1/music_videos/steve-aoki-night-call/clips", { clips: rows }]], api.posts

    cut = shell.calls.find { |c| c.include?("-ss") }
    assert cut.index("-ss") < cut.index("-i"), "seek before input: an accurate in point"
    assert_equal ["40.600", "24.100"], [cut[cut.index("-ss") + 1], cut[cut.index("-t") + 1]]
    assert_includes cut.each_cons(2).to_a, ["-c:v", "libx264"], "re-encoded, never stream-copied"
    assert_includes cut.each_cons(2).to_a, ["-c:a", "aac"]
  end

  def test_refuses_before_the_cast_is_confirmed_and_touches_nothing
    api = FakeApi.new(video(stage: "digested"))
    storage = FakeStorage.new
    shell = FakeShell.new
    error = assert_raises(FindClips::Failure) { run_finder(api:, storage:, shell:) }

    assert_match "confirm the cast", error.message
    assert_empty shell.calls
    assert_empty storage.puts
    assert_empty api.posts
  end

  def test_dry_run_measures_but_cuts_uploads_and_posts_nothing
    api = FakeApi.new(video)
    rows, storage, shell = run_finder(api:, dry_run: true)

    assert_equal 1, rows.size
    refute(shell.calls.any? { |c| c.include?("-ss") })
    assert_empty storage.puts
    assert_empty api.posts
  end

  def test_without_a_local_source_it_downloads_the_stored_one
    _rows, storage, = run_finder(api: FakeApi.new(video), no_source: true, dry_run: true)
    assert_equal [SOURCE_KEY], storage.gets
  end

  def test_silencedetect_output_parses_to_ms_pairs
    err = "silence_start: 0\nsilence_end: 2.616 | silence_duration: 2.6\nsilence_start: 240.26\n"
    assert_equal [[0, 2616], [240_260, Float::INFINITY]], FindClips.silences(err)
  end
end
