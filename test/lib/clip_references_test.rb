# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/clip_references"

# [unit] The Mac side of lettered clip references (bin/clip-references) with
# ffmpeg, R2 and the hub API faked: frames are picked where the chunk's people
# are clearly on screen, the agent's tags are checked, --extract writes the
# stub, --apply draws, uploads under chunks/refs/ and posts each chunk's set,
# and dry runs change nothing. One test draws a real frame with ImageMagick.
class ClipReferencesTest < Minitest::Test
  SOURCE_KEY = "music_videos/test_artist_a/tiled_demo/source/test_artist_a_tiled_demo.mp4"
  SLUG = "test-artist-a-tiled-demo"

  def self.sightings(times, visibility = "clear") = times.map { |t| { "t_ms" => t, "visibility" => visibility } }

  # Person 1 sings 0-20 s, Person 2 leads 40-52 s then Person 3 52-64 s;
  # Person 4 is in the back, partly, at 58 s.
  PERFORMERS = [
    { "ordinal" => 1, "label" => "man in the red jacket", "sightings" => sightings([3_000, 9_000, 15_000]) },
    { "ordinal" => 2, "label" => "woman in the doorway", "sightings" => sightings([42_000, 45_000, 48_000, 51_000]) },
    { "ordinal" => 3, "label" => "long-haired man", "sightings" => sightings([54_000, 57_000, 60_000, 63_000]) },
    { "ordinal" => 4, "label" => "man in the grey hoodie", "sightings" => sightings([58_000], "partial") }
  ].freeze
  CHUNKS = [
    { "ordinal" => 1, "start_ms" => 0, "end_ms" => 25_000 },
    { "ordinal" => 3, "start_ms" => 40_000, "end_ms" => 65_000 }
  ].freeze

  class FakeApi
    attr_reader :calls

    def initialize(video) = (@video = video) && (@calls = [])

    def show(slug)
      @calls << [:show, slug]
      @video
    end

    def post(path, payload)
      @calls << [:post, path, payload]
      { "ok" => true }
    end
  end

  class FakeStorage
    attr_reader :puts

    def initialize = @puts = []

    def put(key, path, type) = @puts << [key, File.basename(path), type]
    def get(*) = raise("no download expected")
  end

  # ffmpeg writes an empty file; magick identify answers 1920x804; a draw copies.
  class FakeShell
    attr_reader :calls

    def initialize = @calls = []

    def call(*cmd)
      @calls << cmd
      if cmd.first == "ffmpeg"
        File.write(cmd.last, "jpg")
      elsif cmd[0..1] == %w[magick identify]
        return ["1920 804", "", true]
      elsif cmd.first == "magick"
        File.write(cmd.last, "lettered")
      end
      ["", "", true]
    end
  end

  def video(alt_swaps: [{ "performer_ordinal" => 2 }, { "performer_ordinal" => 4 }])
    { "slug" => SLUG, "source_id" => "demo", "source_object_key" => SOURCE_KEY, "performers" => PERFORMERS,
      "chunks" => CHUNKS, "alt_videos" => [{ "number" => 1, "slug" => "#{SLUG}-alt-1", "swaps" => alt_swaps }] }
  end

  def runner(dir, api:, shell: FakeShell.new, storage: FakeStorage.new, **opts)
    ClipReferences::Runner.new(api:, storage:, shell:, out: StringIO.new, workdir: dir, source: File.join(dir, "src.mp4"), **opts)
  end

  # --- picking moments ---

  def test_picks_moments_that_show_each_person_in_the_window_clearly
    picked = ClipReferences.pick_times(PERFORMERS, start_ms: 40_000, end_ms: 65_000)

    assert_equal 3, picked.size
    shown = picked.flat_map { |m| m["letters"] }.uniq
    assert_includes shown, "B"
    assert_includes shown, "C"
    picked.each { |m| assert m["t_ms"].between?(40_500, 64_500) }
    picked.each_cons(2) { |a, b| assert b["t_ms"] - a["t_ms"] >= ClipReferences::MIN_GAP_MS }
  end

  def test_focus_prefers_the_alt_videos_swaps
    picked = ClipReferences.pick_times(PERFORMERS, start_ms: 40_000, end_ms: 65_000, focus: [4], count: 1)

    assert_equal 1, picked.size
    assert_includes picked.first["letters"], "D", "the first pick shows the swapped background person"
  end

  def test_a_window_without_sightings_still_gets_two_evenly_spread_frames
    picked = ClipReferences.pick_times(PERFORMERS, start_ms: 100_000, end_ms: 125_000)

    assert_equal 2, picked.size
    assert_equal [], picked.flat_map { |m| m["letters"] }
  end

  # --- the agent's tags ---

  def test_tags_must_be_known_letters_once_inside_the_frame
    known = %w[A B C D]
    ok = [{ "letter" => "B", "x" => 0.4, "y" => 0.3 }]
    assert_equal ok, ClipReferences.check_tags(ok, known:, where: "f")

    bad = [[{ "letter" => "E", "x" => 0.4, "y" => 0.3 }], [{ "letter" => "B", "x" => 1.2, "y" => 0.3 }],
           [{ "letter" => "B", "x" => 0.4, "y" => 0.3, "name" => "Somebody" }], ok + ok, "B"]
    bad.each { |tags| assert_raises(ClipReferences::Failure) { ClipReferences.check_tags(tags, known:, where: "f") } }
  end

  def test_draw_command_places_a_disc_and_the_letter_at_the_fraction
    cmd = ClipReferences.draw_command("in.jpg", "out.jpg", [{ "letter" => "B", "x" => 0.5, "y" => 0.25 }],
                                      width: 1000, height: 600, font: nil)

    assert_equal %w[magick in.jpg], cmd.first(2)
    assert_includes cmd, "circle 500,150 527,150"
    assert_equal "+0-150", cmd[cmd.index("-annotate") + 1]
    assert_equal "B", cmd[cmd.index("-annotate") + 2]
    assert_equal "out.jpg", cmd.last
  end

  # --- the two steps ---

  def test_extract_writes_frames_and_a_stub_for_the_agent
    Dir.mktmpdir do |dir|
      shell = FakeShell.new
      runner(dir, api: FakeApi.new(video), shell:, alt: 1).extract(SLUG)

      doc = JSON.parse(File.read(File.join(dir, "references", SLUG, "tags.json")))
      assert_equal 1, doc["version"]
      assert_equal %w[A B C D], doc["people"].map { |p| p["letter"] }
      assert_equal [false, true, false, true], doc["people"].map { |p| p["swapped"] }
      assert_equal [1, 3], doc["chunks"].map { |c| c["ordinal"] }
      frame = doc["chunks"].last["frames"].first
      assert_equal [], frame["tags"]
      assert File.file?(File.join(dir, "references", SLUG, frame["file"]))
      seek = shell.calls.find { |c| c.first == "ffmpeg" }
      assert seek.index("-ss") < seek.index("-i"), "an accurate seek puts -ss before -i"
    end
  end

  def test_extract_dry_run_stills_nothing
    Dir.mktmpdir do |dir|
      shell = FakeShell.new
      plan = runner(dir, api: FakeApi.new(video), shell:, dry_run: true).extract(SLUG)

      assert_equal 2, plan.size
      assert_empty shell.calls
      refute File.exist?(File.join(dir, "references", SLUG, "tags.json"))
    end
  end

  def test_apply_draws_uploads_and_posts_only_tagged_frames
    Dir.mktmpdir do |dir|
      runner(dir, api: FakeApi.new(video)).extract(SLUG)
      path = File.join(dir, "references", SLUG, "tags.json")
      doc = JSON.parse(File.read(path))
      doc["chunks"].last["frames"].first["tags"] = [{ "letter" => "C", "x" => 0.6, "y" => 0.4 },
                                                     { "letter" => "B", "x" => 0.3, "y" => 0.4 }]
      File.write(path, JSON.generate(doc))
      api = FakeApi.new(video)
      storage = FakeStorage.new

      runner(dir, api:, storage:).apply(SLUG)

      key = MusicVideos::ObjectKeys.chunk_reference(source_key: SOURCE_KEY, ordinal: 3, start_ms: 40_000, end_ms: 65_000, number: 1)
      assert_equal "music_videos/test_artist_a/tiled_demo/chunks/refs/tiled_demo_chunk_03_0040_0105_ref_01.jpg", key
      assert_equal [[key, "chunk_03_ref_01.jpg", "image/jpeg"]], storage.puts
      posts = api.calls.select { |c| c.first == :post }
      assert_equal 1, posts.size, "chunk 1 has no tags and is left as it is"
      assert_equal "/api/v1/music_videos/#{SLUG}/chunks/3/references", posts.first[1]
      assert_equal [{ "object_key" => key, "t_ms" => doc["chunks"].last["frames"].first["t_ms"], "letters" => %w[C B] }],
                   posts.first[2][:frames]
    end
  end

  def test_apply_dry_run_draws_but_uploads_and_posts_nothing
    Dir.mktmpdir do |dir|
      runner(dir, api: FakeApi.new(video)).extract(SLUG)
      path = File.join(dir, "references", SLUG, "tags.json")
      doc = JSON.parse(File.read(path))
      doc["chunks"].first["frames"].first["tags"] = [{ "letter" => "A", "x" => 0.5, "y" => 0.5 }]
      File.write(path, JSON.generate(doc))
      api = FakeApi.new(video)
      storage = FakeStorage.new

      runner(dir, api:, storage:, dry_run: true).apply(SLUG)

      assert_empty storage.puts
      assert_empty(api.calls.select { |c| c.first == :post })
      assert File.file?(File.join(dir, "references", SLUG, "lettered", "chunk_01_ref_01.jpg"))
    end
  end

  def test_apply_refuses_a_rechunked_source_and_a_missing_stub
    Dir.mktmpdir do |dir|
      assert_raises(ClipReferences::Failure) { runner(dir, api: FakeApi.new(video)).apply(SLUG) }

      runner(dir, api: FakeApi.new(video)).extract(SLUG)
      moved = video.merge("chunks" => [{ "ordinal" => 1, "start_ms" => 0, "end_ms" => 15_000 }, CHUNKS.last])
      error = assert_raises(ClipReferences::Failure) { runner(dir, api: FakeApi.new(moved)).apply(SLUG) }
      assert_match(/cut differently/, error.message)
    end
  end

  def test_an_unknown_alt_video_is_refused
    Dir.mktmpdir do |dir|
      assert_raises(ClipReferences::Failure) { runner(dir, api: FakeApi.new(video), alt: 9).extract(SLUG) }
    end
  end

  # The real tool: ImageMagick draws a tag on a synthetic frame, and the
  # pixel under the disc turns the tag's yellow.
  def test_magick_really_draws_the_tag
    skip "ImageMagick is not installed" unless system("command -v magick >/dev/null 2>&1")

    Dir.mktmpdir do |dir|
      src = File.join(dir, "frame.jpg")
      dest = File.join(dir, "lettered.jpg")
      assert system("magick", "-size", "1280x720", "xc:#203040", src)
      tag = [{ "letter" => "B", "x" => 0.25, "y" => 0.5 }] # a 32 px disc at (320, 360)
      assert system(*ClipReferences.draw_command(src, dest, tag, width: 1280, height: 720))

      hex = ->(x, y) { Open3.capture2("magick", dest, "-format", "%[hex:p{#{x},#{y}}]", "info:").first }
      assert_match(/\AF[EF][CDE][0-9A-F][0-3]/, hex.call(296, 360), "inside the disc, left of the letter, is the tag's yellow")
      assert_equal hex.call(1000, 600), hex.call(900, 100), "the rest of the frame is untouched"
      refute_match(/\AF[EF][CDE]/, hex.call(1000, 600))
    end
  end
end
