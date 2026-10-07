# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/digest_video"

# [unit] The Instagram path of bin/digest-video: host and link routing, the
# portrait-safe selector, the allowlist, credits from the creator, and the
# refusals (carousel, share link, login wall, silent reel). yt-dlp,
# ffmpeg/ffprobe, R2 and the hub API are fakes.
class DigestVideoInstagramTest < Minitest::Test
  ID = "Cabc-DEF_12"
  PAGE = "https://www.instagram.com/reel/#{ID}/"
  CAPTION = "secretcaption words ft. Sample Singer #secrettag"
  KEY = "music_videos/test_creator/instagram_cabc_def_12/source/test_creator_instagram_cabc_def_12_feat_sample_singer"
  SIGNED = "https://scontent.cdninstagram.com/v/t50/abc.mp4?efg=secretsig&oe=ABC&ip=203.0.113.7"
  WALL = "ERROR: [Instagram] #{ID}: Instagram sent an empty media response. Check if this post is accessible in " \
         "your browser without being logged-in. If it is not, then use --cookies-from-browser or --cookies"
  # What yt-dlp writes for a reel, with caption text, a session and signed URLs planted.
  INFO = {
    "_type" => "video", "id" => ID, "title" => "Video by testcreator", "description" => CAPTION,
    "uploader" => "Test Creator", "uploader_id" => "25000001", "channel" => "testcreator",
    "upload_date" => "20260901", "webpage_url" => "#{PAGE}?igsh=secrettracker", "extractor" => "Instagram",
    "width" => 720, "height" => 1280, "fps" => 30, "vcodec" => "avc1.64001E", "acodec" => "mp4a.40.5",
    "comments" => [{ "text" => "secretcomment" }], "thumbnail" => SIGNED, "url" => SIGNED,
    "http_headers" => { "Referer" => "https://www.instagram.com/" }, "cookies" => "sessionid=secretcookie",
    "formats" => [{ "url" => SIGNED, "cookies" => "sessionid=secretcookie", "http_headers" => { "User-Agent" => "x" } }]
  }.freeze

  class FakeShell
    attr_reader :calls

    def initialize(h264_available: true, codecs: %w[h264 aac], info: INFO, wall: false)
      @h264_available = h264_available
      @codecs = codecs
      @info = info
      @wall = wall
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
      return ["", WALL, false] if @wall && !cmd.include?("--cookies-from-browser")
      return ["", "Requested format is not available", false] if !@h264_available && cmd.include?(DigestVideo::INSTAGRAM_H264)

      dir = cmd[cmd.index("-P") + 1]
      File.write(File.join(dir, "#{ID}.mp4"), "video")
      File.write(File.join(dir, "#{ID}.info.json"), JSON.generate(@info))
      ["", "", true]
    end

    def probe(path)
      codecs = path.end_with?(".h264.mp4") ? %w[h264 aac] : @codecs
      streams = %w[video audio].zip(codecs).select(&:last).map { |type, name| { "codec_type" => type, "codec_name" => name } }
      [JSON.generate("streams" => streams, "format" => { "duration" => "18.99" }), "", true]
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
      { "slug" => "test-creator-instagram-cabc-def-12", "artists" => [], "unresolved_credits" => [] }
    end
  end

  def run_digest(url = PAGE, shell: FakeShell.new, **options)
    Dir.mktmpdir do |dir|
      storage = FakeStorage.new
      api = FakeApi.new
      out = StringIO.new
      DigestVideo::Runner.new(workdir: dir, shell: shell, storage: storage, api: api, out: out,
                              encoder: "libx264", **options).call(url)
      yield shell, storage, api, File.join(dir, ID)
    end
  end

  def ytdlp_calls(shell) = shell.calls.select { |c| File.basename(c.first) == "yt-dlp" }

  def test_instagram_hosts_route_to_instagram
    [PAGE, "https://instagram.com/p/#{ID}/", "https://m.instagram.com/tv/#{ID}/"].each do |url|
      assert_equal "instagram", DigestVideo.platform_for(url), url
    end
    assert_raises(DigestVideo::Failure) { DigestVideo.platform_for("https://evilinstagram.com/reel/#{ID}/") }
  end

  def test_instagram_id_from_every_post_shape
    ["/reel/#{ID}/", "/reels/#{ID}/", "/p/#{ID}/", "/tv/#{ID}/", "/some.handle/reel/#{ID}/",
     "/reel/#{ID}/?igsh=abc", "/p/#{ID}/embed/"].each do |path|
      assert_equal ID, DigestVideo.instagram_id("https://www.instagram.com#{path}"), path
    end
  end

  def test_a_share_link_and_a_profile_are_refused_with_the_remedy
    share = assert_raises(DigestVideo::Failure) { DigestVideo.instagram_id("https://www.instagram.com/share/reel/BAbc1/") }
    assert_match(/share link has no post id.*paste the \/reel\/ or \/p\/ URL/, share.message)
    profile = assert_raises(DigestVideo::Failure) { DigestVideo.instagram_id("https://www.instagram.com/testcreator/") }
    assert_match(/no Instagram post id/, profile.message)
  end

  def test_audio_and_story_pages_are_refused_as_not_a_post
    ["/reels/audio/1234567890/", "/reel/audio/1234567890/", "/some.handle/reels/audio/1/",
     "/stories/testcreator/3570766765028588805/", "/stories/p/1/"].each do |path|
      error = assert_raises(DigestVideo::Failure, path) { DigestVideo.instagram_id("https://www.instagram.com#{path}") }
      assert_match(/not a single Instagram post/, error.message, path)
    end
    assert_equal ID, DigestVideo.instagram_id("https://www.instagram.com/audio/reel/#{ID}/"),
                 "a handle named audio is still a handle"
  end

  def test_the_page_drops_the_handle_and_the_tracking_query
    assert_equal PAGE, DigestVideo.instagram_page("https://www.instagram.com/some.handle/reels/#{ID}/?igsh=abc", ID)
    assert_equal "https://www.instagram.com/p/#{ID}/", DigestVideo.instagram_page("https://instagram.com/p/#{ID}", ID)
  end

  def test_the_selector_has_no_height_cap
    refute_includes DigestVideo::INSTAGRAM_H264, "height", "a portrait reel is 1280 or 1920 tall"
    refute_includes DigestVideo::INSTAGRAM_ANY, "height"
    assert_includes DigestVideo::H264, "height<=1080", "YouTube keeps its cap"
  end

  def test_instagram_allowlist_drops_caption_comments_session_and_signed_urls
    stored = DigestVideo.sanitize_info(INFO.merge("webpage_url" => PAGE), platform: "instagram")
    assert_empty stored.keys - DigestVideo::INSTAGRAM_INFO_ALLOWLIST
    refute stored.key?("title")
    assert_equal [PAGE, "25000001", "testcreator"], stored.values_at("webpage_url", "uploader_id", "channel")
    json = JSON.generate(stored)
    %w[secretcaption secrettag secretcomment secretcookie secretsig].each { |bad| refute_includes json, bad }
  end

  def test_a_tracked_page_url_is_dropped_unless_canonical
    refute DigestVideo.sanitize_info(INFO, platform: "instagram").key?("webpage_url")
  end

  def test_credits_are_the_display_name_then_feat_names
    assert_equal ["Test Creator", "Sample Singer"], DigestVideo.instagram_credits(INFO)
    assert_equal ["testcreator", "Sample Singer"], DigestVideo.instagram_credits(INFO.merge("uploader" => " "))
    prose = INFO.merge("description" => "Artist Name - Other Song secretcaption\nsecond line ft. Nobody")
    assert_equal ["Test Creator"], DigestVideo.instagram_credits(prose)
    assert_equal [], DigestVideo.instagram_credits(INFO.merge("uploader" => nil, "channel" => nil))
  end

  def test_a_display_name_with_no_key_safe_characters_falls_back_to_the_handle
    ["🔥🎤🔥", "米津玄師", "  "].each do |name|
      assert_equal %w[testcreator], DigestVideo.instagram_credits(INFO.merge("uploader" => name, "description" => "x")), name
    end
    assert_equal ["Beyoncé"], DigestVideo.instagram_credits(INFO.merge("uploader" => "Beyoncé", "description" => "x"))
    unsafe_feat = INFO.merge("description" => "new one ft. 米津玄師 & Sample Singer")
    assert_equal ["Test Creator", "Sample Singer"], DigestVideo.instagram_credits(unsafe_feat)
  end

  def test_an_emoji_display_name_digests_under_the_handle
    shell = FakeShell.new(info: INFO.merge("uploader" => "🔥🎤🔥"))
    run_digest(shell: shell) do |_shell, storage, api, _dir|
      assert_equal %w[testcreator Sample\ Singer], api.payloads.first[:credited_artists]
      assert(storage.puts.keys.all? { |k| k.start_with?("music_videos/testcreator/instagram_cabc_def_12/") }, storage.puts.keys.inspect)
    end
  end

  def test_tiktok_credits_are_unchanged_by_the_shared_helper
    info = { "channel" => "Test Creator", "uploader" => "testcreator", "title" => "x ft. Sample Singer #fyp" }
    assert_equal ["Test Creator", "Sample Singer"], DigestVideo.tiktok_credits(info)
  end

  def test_instagram_digest_uploads_and_posts_no_caption_text
    run_digest("https://www.instagram.com/some.handle/reels/#{ID}/?igsh=secrettracker") do |shell, storage, api, _dir|
      ytdlp = ytdlp_calls(shell).first
      assert_equal DigestVideo::INSTAGRAM_H264, ytdlp[ytdlp.index("-f") + 1]
      refute_includes ytdlp, "--write-subs"
      refute_includes ytdlp, "--cookies-from-browser"
      assert_equal ["#{KEY}.mp4", "#{KEY}.info.json"], storage.puts.keys

      payload = api.payloads.first
      assert_equal ["instagram", ID, PAGE, "Instagram #{ID}", 18_990],
                   payload.values_at(:platform, :source_id, :source_url, :title, :duration_ms)
      assert_equal ["Test Creator", "Sample Singer"], payload[:credited_artists]
      assert_equal PAGE, JSON.parse(storage.puts["#{KEY}.info.json"].first)["webpage_url"]
      sent = JSON.generate(payload) + storage.puts.values.map(&:first).join
      %w[secretcaption secrettag secretcomment secretcookie secretsig secrettracker].each { |bad| refute_includes sent, bad }
    end
  end

  def test_no_h264_falls_back_uncapped_and_converts
    run_digest(shell: FakeShell.new(h264_available: false, codecs: %w[vp9 aac])) do |shell, storage, _api, _dir|
      selectors = ytdlp_calls(shell).map { |c| c[c.index("-f") + 1] }
      assert_equal [DigestVideo::INSTAGRAM_H264, DigestVideo::INSTAGRAM_ANY], selectors
      assert_equal "converted", storage.puts["#{KEY}.mp4"].first
    end
  end

  def test_a_login_wall_fails_once_and_names_the_flag
    shell = FakeShell.new(wall: true)
    error = assert_raises(DigestVideo::Failure) { run_digest(shell: shell) { flunk "should not finish" } }
    assert_match(/wants a login.*empty media response.*--cookies-from-browser chrome/, error.message)
    assert_equal 1, ytdlp_calls(shell).size, "a second anonymous try only spends the rate limit"
  end

  def test_the_lent_session_reaches_yt_dlp_and_is_scrubbed_from_disk
    run_digest(shell: FakeShell.new(wall: true), cookies_from_browser: "chrome") do |shell, storage, _api, dir|
      ytdlp = ytdlp_calls(shell).first
      assert_equal "chrome", ytdlp[ytdlp.index("--cookies-from-browser") + 1]
      on_disk = File.read(File.join(dir, "#{ID}.info.json"))
      refute_includes on_disk, "secretcookie"
      refute_includes on_disk, "http_headers"
      assert_equal ID, JSON.parse(on_disk)["id"], "the rest of the info.json survives for a --from-dir retry"
      refute_includes storage.puts.values.map(&:first).join, "secretcookie"
    end
  end

  def test_without_a_lent_session_the_info_json_is_left_as_written
    run_digest do |_shell, _storage, _api, dir|
      assert_includes File.read(File.join(dir, "#{ID}.info.json")), "http_headers"
    end
  end

  def test_a_carousel_is_refused_before_upload
    shell = FakeShell.new(info: { "_type" => "playlist", "id" => ID, "playlist_count" => 3 })
    error = assert_raises(DigestVideo::Failure) { run_digest(shell: shell) { flunk "should not finish" } }
    assert_match(/a post with 3 videos/, error.message)
  end

  def test_a_silent_reel_is_refused_before_upload
    shell = FakeShell.new(codecs: ["h264", nil])
    error = assert_raises(DigestVideo::Failure) { run_digest(shell: shell) { flunk "should not finish" } }
    assert_match(/no audio track/, error.message)
    refute(shell.calls.any? { |c| File.basename(c.first) == "ffmpeg" })
  end

  def test_no_creator_is_a_failure_before_upload
    shell = FakeShell.new(info: INFO.merge("uploader" => nil, "channel" => nil))
    error = assert_raises(DigestVideo::Failure) { run_digest(shell: shell) { flunk "should not finish" } }
    assert_match(/no creator/, error.message)
  end
end
