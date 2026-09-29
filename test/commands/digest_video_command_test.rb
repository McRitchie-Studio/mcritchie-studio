# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

# [integration] bin/digest-video as a process, on paths that make no network call.
class DigestVideoCommandTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/digest-video", __dir__)

  def run_script(*args)
    Open3.capture3(SCRIPT, *args)
  end

  # TikTok is built now (was "not built yet"); a missing yt-dlp is a clean refusal.
  def test_tiktok_without_ytdlp_fails_cleanly
    Dir.mktmpdir do |dir|
      _out, err, status = Open3.capture3({ "YT_DLP" => File.join(dir, "no-yt-dlp") }, SCRIPT,
                                         "https://www.tiktok.com/@a/video/1", "--dry-run", "--workdir", dir)
      refute status.success?
      assert_includes err, "digest-video: no-yt-dlp not found"
      refute_includes err, "Errno::ENOENT"
    end
  end

  def test_instagram_is_not_built_yet
    _out, err, status = run_script("https://www.instagram.com/reel/abc/")
    refute status.success?
    assert_includes err, "not built yet: download-instagram"
  end

  def test_needs_exactly_one_url
    _out, err, status = run_script
    refute status.success?
    assert_includes err, "Usage"
    _out, err, status = run_script("https://youtu.be/a", "https://youtu.be/b")
    refute status.success?
    assert_includes err, "exactly one URL"
  end

  def test_help_exits_zero
    out, _err, status = run_script("--help")
    assert status.success?
    assert_includes out, "--production"
  end
end
