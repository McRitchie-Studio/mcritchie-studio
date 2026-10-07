# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/digest_video"

# [unit] The TikTok path of bin/digest-video: host routing, the TikTok
# allowlist, and credits from the creator plus feat.-style caption credits.
# yt-dlp, ffmpeg/ffprobe, R2 and the hub API are fakes.
class DigestVideoTiktokTest < Minitest::Test
  ID = "7400000000000000001"
  PAGE = "https://www.tiktok.com/@testcreator/video/#{ID}"
  CAPTION = "secretcaption words ft. Sample Singer #fyp #secrettag"
  KEY = "music_videos/test_creator/tiktok_#{ID}/source/test_creator_tiktok_#{ID}_feat_sample_singer"
  SIGNED = "https://v16-webapp.tiktok.com/video/tos/abc?expire=1&signature=ABC&ip=203.0.113.7"
  # What yt-dlp writes for a TikTok, with caption text and signed URLs planted.
  INFO = {
    "id" => ID, "title" => CAPTION, "description" => CAPTION, "uploader" => "testcreator",
    "uploader_id" => "6800000000000000001", "channel" => "Test Creator", "channel_id" => "MS4wLjABAAAA",
    "creator" => "Test Creator", "upload_date" => "20260901", "duration" => 21, "webpage_url" => PAGE,
    "extractor" => "TikTok", "width" => 1080, "height" => 1920, "vcodec" => "h264", "acodec" => "aac",
    "track" => "secretcaption sound", "tags" => ["secrettag"], "comments" => [{ "text" => "secretcomment" }],
    "formats" => [{ "url" => SIGNED }], "thumbnail" => SIGNED, "thumbnails" => [{ "url" => SIGNED }],
    "http_headers" => { "Cookie" => "secretcookie" }, "url" => SIGNED
  }.freeze

  class FakeShell
    attr_reader :calls

    def initialize(h264_available: true, codecs: %w[h264 aac], info: INFO)
      @h264_available = h264_available
      @codecs = codecs
      @info = info
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
      return ["", "Requested format is not available", false] if !@h264_available && cmd.include?(DigestVideo::TIKTOK_H264)

      dir = cmd[cmd.index("-P") + 1]
      File.write(File.join(dir, "#{ID}.mp4"), "video")
      File.write(File.join(dir, "#{ID}.info.json"), JSON.generate(@info))
      ["", "", true]
    end

    def probe(path)
      codecs = path.end_with?(".h264.mp4") ? %w[h264 aac] : @codecs
      [JSON.generate("streams" => [{ "codec_type" => "video", "codec_name" => codecs[0] },
                                   { "codec_type" => "audio", "codec_name" => codecs[1] }],
                     "format" => { "duration" => "21.05" }), "", true]
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

    def authenticate = true

    def create(payload)
      @payloads << payload
      { "slug" => "test-creator-tiktok-#{ID}", "artists" => [], "unresolved_credits" => [] }
    end
  end

  def run_digest(url = PAGE, shell: FakeShell.new)
    Dir.mktmpdir do |dir|
      storage = FakeStorage.new
      api = FakeApi.new
      out = StringIO.new
      DigestVideo::Runner.new(workdir: dir, shell: shell, storage: storage, api: api, out: out,
                              encoder: "libx264").call(url)
      yield shell, storage, api, out.string
    end
  end

  def test_tiktok_hosts_route_to_tiktok
    [PAGE, "https://tiktok.com/@a/video/1", "https://vm.tiktok.com/ZMabc123/",
     "https://vt.tiktok.com/ZSabc123/", "https://m.tiktok.com/v/1.html"].each do |url|
      assert_equal "tiktok", DigestVideo.platform_for(url), url
    end
    assert_raises(DigestVideo::Failure) { DigestVideo.platform_for("https://eviltiktok.com/@a/video/1") }
  end

  def test_tiktok_id_from_the_page_url_only
    assert_equal ID, DigestVideo.tiktok_id(PAGE)
    assert_nil DigestVideo.tiktok_id("https://vm.tiktok.com/ZMabc123/")
  end

  def test_tiktok_allowlist_drops_caption_tags_comments_and_signed_urls
    stored = DigestVideo.sanitize_info(INFO, platform: "tiktok")
    assert_empty stored.keys - DigestVideo::TIKTOK_INFO_ALLOWLIST
    refute stored.key?("title"), "a TikTok title is the caption"
    assert_equal PAGE, stored["webpage_url"]
    assert_equal "6800000000000000001", stored["uploader_id"]
    assert_equal "Test Creator", stored["channel"]
    json = JSON.generate(stored)
    %w[secretcaption secrettag secretcomment secretcookie signature= expire=].each { |bad| refute_includes json, bad }
  end

  def test_youtube_allowlist_is_unchanged
    assert_equal DigestVideo::INFO_ALLOWLIST, DigestVideo.info_allowlist("youtube")
    refute_includes DigestVideo::INFO_ALLOWLIST, "uploader_id"
  end

  def test_credits_are_the_creator_and_feat_names_only
    assert_equal ["Test Creator", "Sample Singer"], DigestVideo.tiktok_credits(INFO)
    only_creator = INFO.merge("title" => "Artist Name - Other Song secretcaption", "channel" => nil)
    assert_equal ["Test Creator"], DigestVideo.tiktok_credits(only_creator)
    mention = INFO.merge("title" => "new one (feat. @samplesinger) #fyp\nsecond line ft. Nobody")
    assert_equal ["Test Creator", "samplesinger"], DigestVideo.tiktok_credits(mention)
    rambling = INFO.merge("title" => "dance ft. my whole family at the beach this summer")
    assert_equal ["Test Creator"], DigestVideo.tiktok_credits(rambling)
    handle_only = INFO.merge("channel" => nil, "creator" => nil)
    assert_equal ["testcreator", "Sample Singer"], DigestVideo.tiktok_credits(handle_only)
  end

  def test_tiktok_digest_uploads_and_posts_no_caption_text
    run_digest do |shell, storage, api, _out|
      ytdlp = shell.calls.first
      assert_equal DigestVideo::TIKTOK_H264, ytdlp[ytdlp.index("-f") + 1]
      refute_includes ytdlp, "--write-subs"
      assert_includes ytdlp, "--write-info-json"
      assert_equal ["#{KEY}.mp4", "#{KEY}.info.json"], storage.puts.keys

      payload = api.payloads.first
      assert_equal ["tiktok", ID, PAGE, "TikTok #{ID}", 21_050],
                   payload.values_at(:platform, :source_id, :source_url, :title, :duration_ms)
      assert_equal ["Test Creator", "Sample Singer"], payload[:credited_artists]
      assert_equal({ "cues" => [], "sections" => [] }, payload[:caption_timing])
      sent = JSON.generate(payload) + storage.puts.values.map(&:first).join
      %w[secretcaption secrettag secretcomment signature=].each { |bad| refute_includes sent, bad }
    end
  end

  def test_short_link_reads_the_id_from_info_json
    run_digest("https://vm.tiktok.com/ZMabc123/") do |_shell, storage, api, _out|
      assert_equal ID, api.payloads.first[:source_id]
      assert_includes storage.puts.keys, "#{KEY}.mp4"
    end
  end

  def test_h265_only_falls_back_and_converts
    run_digest(shell: FakeShell.new(h264_available: false, codecs: %w[hevc aac])) do |shell, storage, _api, _out|
      selectors = shell.calls.select { |c| File.basename(c.first) == "yt-dlp" }.map { |c| c[c.index("-f") + 1] }
      assert_equal [DigestVideo::TIKTOK_H264, DigestVideo::ANY], selectors
      ffmpeg = shell.calls.find { |c| File.basename(c.first) == "ffmpeg" }
      assert_equal "aac", ffmpeg[ffmpeg.index("-c:a") + 1]
      assert_equal "converted", storage.puts["#{KEY}.mp4"].first
    end
  end

  def test_a_non_latin_channel_falls_back_to_the_handle
    assert_equal %w[testcreator], DigestVideo.tiktok_credits(INFO.merge("channel" => "米津玄師", "creator" => "🎤",
                                                                        "title" => "x"))
  end

  def test_no_creator_is_a_failure_before_upload
    shell = FakeShell.new(info: INFO.merge("channel" => nil, "creator" => nil, "uploader" => nil))
    error = assert_raises(DigestVideo::Failure) { run_digest(shell: shell) { flunk "should not finish" } }
    assert_match(/no creator/, error.message)
  end
end
