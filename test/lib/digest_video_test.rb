# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../../bin/lib/digest_video"

# [unit] The agent side of `digest video <url>` (bin/digest-video) with every
# network call stubbed: yt-dlp, ffmpeg/ffprobe, R2 and the hub API are fakes.
class DigestVideoTest < Minitest::Test
  URL = "https://www.youtube.com/watch?v=Sa7GSJJ_lOo"
  TITLE = "Steve Aoki - Night Call feat. Lil Yachty & Migos (Official Video) [Ultra Music]"
  KEY = "music_videos/steve_aoki/night_call/source/steve_aoki_night_call_feat_lil_yachty_migos"
  VTT = "WEBVTT\n\n00:00:05.000 --> 00:00:07.000\nsecretlyric words\n"
  SIGNED = "https://rr3---sn-abc.googlevideo.com/videoplayback?expire=1&ip=203.0.113.7&signature=ABC"
  # What yt-dlp writes, with lyric text and signed URLs planted where they really occur.
  INFO = {
    "id" => "Sa7GSJJ_lOo", "title" => TITLE, "uploader" => "Ultra Records", "channel" => "Ultra Records",
    "channel_id" => "UC1", "upload_date" => "20170501", "duration" => 243, "webpage_url" => URL,
    "extractor" => "youtube", "width" => 1920, "height" => 1080, "fps" => 25, "vcodec" => "avc1.640028",
    "acodec" => SIGNED, "description" => "secretlyric in the description",
    "tags" => ["secretlyric in a tag"], "chapters" => [{ "title" => "secretlyric chapter", "start_time" => 0 }],
    "formats" => [{ "url" => SIGNED }], "requested_formats" => [{ "url" => SIGNED }],
    "thumbnail" => "https://i.ytimg.com/vi/x/maxres.jpg?sqp=secret", "thumbnails" => [{ "url" => SIGNED }],
    "http_headers" => { "User-Agent" => "x" }, "subtitles" => { "en" => [{ "url" => SIGNED }] },
    "automatic_captions" => { "en" => [{ "url" => SIGNED }] }, "url" => SIGNED, "manifest_url" => SIGNED
  }.freeze

  # Records every command; yt-dlp writes the files a real download leaves.
  class FakeShell
    attr_reader :calls

    def initialize(h264_available: true, codecs: %w[h264 aac])
      @h264_available = h264_available
      @codecs = codecs
      @calls = []
    end

    def call(*cmd)
      @calls << cmd
      case File.basename(cmd.first)
      when "yt-dlp" then ytdlp(cmd)
      when "ffprobe" then probe(cmd.last)
      when "ffmpeg" then File.write(cmd.last, "converted") && ["", "", true]
      end
    end

    private

    def ytdlp(cmd)
      return ["", "Requested format is not available", false] if !@h264_available && cmd.include?(DigestVideo::H264)

      dir = cmd[cmd.index("-P") + 1]
      File.write(File.join(dir, "Sa7GSJJ_lOo.mp4"), "video")
      File.write(File.join(dir, "Sa7GSJJ_lOo.en.vtt"), VTT)
      File.write(File.join(dir, "Sa7GSJJ_lOo.info.json"), JSON.generate(INFO))
      ["", "", true]
    end

    def probe(path)
      codecs = path.end_with?(".h264.mp4") ? %w[h264 aac] : @codecs
      [JSON.generate("streams" => [{ "codec_type" => "video", "codec_name" => codecs[0] },
                                   { "codec_type" => "audio", "codec_name" => codecs[1] }],
                     "format" => { "duration" => "243.117" }), "", true]
    end
  end

  class FakeStorage
    attr_reader :puts

    def initialize(log = []) = (@puts = {}) && (@log = log)

    def put(key, path, content_type)
      @log << :put
      @puts[key] = [File.read(path), content_type]
    end
  end

  class FakeApi
    attr_reader :payloads

    def initialize(log = []) = (@payloads = []) && (@log = log)

    def authenticate = @log << :authenticate

    def create(payload)
      @log << :create
      @payloads << payload
      { "slug" => "steve-aoki-night-call", "artists" => [], "unresolved_credits" => [] }
    end
  end

  def run_digest(shell: FakeShell.new, dry_run: false, **opts)
    Dir.mktmpdir do |dir|
      log = []
      storage = FakeStorage.new(log)
      api = FakeApi.new(log)
      out = StringIO.new
      DigestVideo::Runner.new(workdir: dir, shell: shell, storage: storage, api: api, out: out,
                              dry_run: dry_run, encoder: "libx264", **opts).call(URL)
      yield shell, storage, api, out.string, log, File.join(dir, "Sa7GSJJ_lOo")
    end
  end

  def test_platform_by_host
    assert_equal "youtube", DigestVideo.platform_for(URL)
    assert_equal "youtube", DigestVideo.platform_for("https://youtu.be/Sa7GSJJ_lOo")
    assert_equal "youtube", DigestVideo.platform_for("https://music.youtube.com/watch?v=Sa7GSJJ_lOo")
    assert_equal "tiktok", DigestVideo.platform_for("https://www.tiktok.com/@a/video/1") # built: was NotBuilt
    assert_equal "instagram", DigestVideo.platform_for("https://instagram.com/reel/x") # built: was NotBuilt
    assert_raises(DigestVideo::Failure) { DigestVideo.platform_for("https://vimeo.com/1") }
  end

  def test_youtube_id_forms
    assert_equal "Sa7GSJJ_lOo", DigestVideo.youtube_id(URL)
    assert_equal "Sa7GSJJ_lOo", DigestVideo.youtube_id("https://youtu.be/Sa7GSJJ_lOo?t=3")
    assert_equal "Sa7GSJJ_lOo", DigestVideo.youtube_id("https://www.youtube.com/shorts/Sa7GSJJ_lOo")
  end

  def test_h264_download_uploads_and_posts_timings_only
    run_digest do |shell, storage, api, out|
      ytdlp = shell.calls.first
      assert_includes ytdlp, DigestVideo::H264
      %w[--write-info-json --write-auto-subs].each { |flag| assert_includes ytdlp, flag }
      assert_equal "vtt", ytdlp[ytdlp.index("--sub-format") + 1]
      assert_empty(shell.calls.select { |c| File.basename(c.first) == "ffmpeg" })

      assert_equal ["#{KEY}.mp4", "#{KEY}.info.json"], storage.puts.keys
      assert_equal ["video", "video/mp4"], storage.puts["#{KEY}.mp4"]
      refute_includes storage.puts["#{KEY}.info.json"].first, "secretlyric"

      payload = api.payloads.first
      assert_equal %w[youtube Sa7GSJJ_lOo] + [243_117], payload.values_at(:platform, :source_id, :duration_ms)
      assert_equal [{ "start_ms" => 5_000, "end_ms" => 7_000 }], payload[:caption_timing]["cues"]
      refute_includes JSON.generate(payload), "secretlyric"
      assert_includes out, "#{KEY}.mp4"
    end
  end

  def test_a_video_is_a_music_video_unless_typed_cinematic
    run_digest { |_shell, _storage, api| assert_equal "music_video", api.payloads.first[:kind] }
    run_digest(kind: "cinematic") { |_shell, _storage, api| assert_equal "cinematic", api.payloads.first[:kind] }
    error = assert_raises(DigestVideo::Failure) { run_digest(kind: "documentary") { flunk "never runs" } }
    assert_match "kind must be one of: music_video, cinematic", error.message
  end

  def test_vp9_fallback_converts_with_aac_audio
    run_digest(shell: FakeShell.new(h264_available: false, codecs: %w[vp9 opus])) do |shell, storage, _api, _out|
      assert_equal 2, shell.calls.count { |c| File.basename(c.first) == "yt-dlp" }
      ffmpeg = shell.calls.find { |c| File.basename(c.first) == "ffmpeg" }
      assert_equal "libx264", ffmpeg[ffmpeg.index("-c:v") + 1]
      assert_equal "aac", ffmpeg[ffmpeg.index("-c:a") + 1]
      assert_equal "converted", storage.puts["#{KEY}.mp4"].first
    end
  end

  def test_dry_run_touches_neither_r2_nor_the_api
    run_digest(dry_run: true) do |_shell, storage, api, out, log, dir|
      assert_empty log
      refute_empty Dir.glob(File.join(dir, "*.vtt")), "a later --from-dir run still needs the captions"
      assert_empty storage.puts
      assert_empty api.payloads
      assert_includes out, "dry run"
    end
  end

  def test_sanitizer_keeps_only_the_allowlist
    stored = DigestVideo.sanitize_info(INFO)
    assert_empty stored.keys - DigestVideo::INFO_ALLOWLIST
    assert_equal URL, stored["webpage_url"]
    assert_equal "Ultra Records", stored["uploader"]
    refute stored.key?("acodec"), "a signed URL in an allowlisted field is dropped"
    json = JSON.generate(stored)
    %w[secretlyric googlevideo signature= ip= sqp= User-Agent].each { |bad| refute_includes json, bad }
  end

  def test_stored_info_json_is_the_sanitized_one
    run_digest do |_shell, storage, _api, _out|
      stored = JSON.parse(storage.puts["#{KEY}.info.json"].first)
      assert_equal DigestVideo.sanitize_info(INFO), stored
      refute_match(/secretlyric|signature=/, JSON.generate(stored))
    end
  end

  def test_logs_in_before_any_upload
    run_digest do |_shell, _storage, _api, _out, log|
      assert_equal %i[authenticate put put create], log
    end
  end

  def test_caption_files_are_removed_after_parsing
    run_digest do |_shell, _storage, api, _out, _log, dir|
      assert_equal 1, api.payloads.first[:caption_timing]["cues"].size
      assert_empty Dir.glob(File.join(dir, "*.vtt"))
    end
  end

  # Stands in for ChunkTiling::Runner (its own test covers the cutting).
  class FakeTiler
    attr_reader :calls

    def initialize(log, problem: nil)
      @log = log
      @problem = problem
      @calls = []
    end

    def problem = @problem

    def call(video, mp4)
      @log << :tile
      @calls << [video, File.basename(mp4)]
      []
    end
  end

  def test_tiles_the_recorded_source_right_after_the_record
    log = []
    tiler = FakeTiler.new(log)
    Dir.mktmpdir do |dir|
      DigestVideo::Runner.new(workdir: dir, shell: FakeShell.new, storage: FakeStorage.new(log), api: FakeApi.new(log),
                              out: StringIO.new, encoder: "libx264", tiler:).call(URL)
    end
    assert_equal %i[authenticate put put create tile], log
    video, mp4 = tiler.calls.first
    assert_equal "steve-aoki-night-call", video["slug"], "the hub's record, not the payload"
    assert_equal "Sa7GSJJ_lOo.mp4", mp4, "the playable file that was stored"
  end

  def test_dry_run_plans_the_chunks_from_the_local_file_and_records_nothing
    log = []
    tiler = FakeTiler.new(log)
    Dir.mktmpdir do |dir|
      DigestVideo::Runner.new(workdir: dir, shell: FakeShell.new, storage: FakeStorage.new(log), api: FakeApi.new(log),
                              out: StringIO.new, encoder: "libx264", dry_run: true, tiler:).call(URL)
    end
    assert_equal %i[tile], log
    video, = tiler.calls.first
    assert_equal [243_117, "#{KEY}.mp4", []], video.values_at("duration_ms", "source_object_key", "chunks")
  end

  def test_a_tiling_that_cannot_cut_stops_before_any_upload
    log = []
    error = assert_raises(DigestVideo::Failure) do
      Dir.mktmpdir do |dir|
        DigestVideo::Runner.new(workdir: dir, shell: FakeShell.new, storage: FakeStorage.new(log), api: FakeApi.new(log),
                                out: StringIO.new, encoder: "libx264", tiler: FakeTiler.new(log, problem: "no")).call(URL)
      end
    end
    assert_equal "no", error.message
    assert_empty log
  end

  def test_buckets_default_to_dev
    assert_equal "mcritchie-studio-dev", DigestVideo.target(production: false)[:bucket]
    assert_equal "mcritchie-studio-production", DigestVideo.target(production: true)[:bucket]
    assert_equal "dev", DigestVideo.target(production: false)[:suffix]
  end
end
