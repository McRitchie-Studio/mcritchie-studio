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
      File.write(File.join(dir, "Sa7GSJJ_lOo.info.json"),
                 JSON.generate("id" => "Sa7GSJJ_lOo", "title" => TITLE, "uploader" => "Ultra Records",
                               "webpage_url" => URL, "description" => "secretlyric in the description"))
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

    def initialize = @puts = {}

    def put(key, path, content_type) = @puts[key] = [File.read(path), content_type]
  end

  class FakeApi
    attr_reader :payloads

    def initialize = @payloads = []

    def create(payload)
      @payloads << payload
      { "slug" => "steve-aoki-night-call", "artists" => [], "unresolved_credits" => [] }
    end
  end

  def run_digest(shell: FakeShell.new, dry_run: false)
    Dir.mktmpdir do |dir|
      storage = FakeStorage.new
      api = FakeApi.new
      out = StringIO.new
      DigestVideo::Runner.new(workdir: dir, shell: shell, storage: storage, api: api, out: out,
                              dry_run: dry_run, encoder: "libx264").call(URL)
      yield shell, storage, api, out.string
    end
  end

  def test_platform_by_host
    assert_equal "youtube", DigestVideo.platform_for(URL)
    assert_equal "youtube", DigestVideo.platform_for("https://youtu.be/Sa7GSJJ_lOo")
    assert_equal "youtube", DigestVideo.platform_for("https://music.youtube.com/watch?v=Sa7GSJJ_lOo")
    error = assert_raises(DigestVideo::NotBuilt) { DigestVideo.platform_for("https://www.tiktok.com/@a/video/1") }
    assert_equal "not built yet: download-tiktok", error.message
    error = assert_raises(DigestVideo::NotBuilt) { DigestVideo.platform_for("https://instagram.com/reel/x") }
    assert_equal "not built yet: download-instagram", error.message
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
    run_digest(dry_run: true) do |_shell, storage, api, out|
      assert_empty storage.puts
      assert_empty api.payloads
      assert_includes out, "dry run"
    end
  end

  def test_buckets_default_to_dev
    assert_equal "mcritchie-studio-dev", DigestVideo.target(production: false)[:bucket]
    assert_equal "mcritchie-studio-production", DigestVideo.target(production: true)[:bucket]
    assert_equal "dev", DigestVideo.target(production: false)[:suffix]
  end
end
