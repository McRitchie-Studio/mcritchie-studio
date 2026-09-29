# frozen_string_literal: true

require "minitest/autorun"
require "open3"

# [integration] bin/digest-video as a process, on paths that make no network call.
class DigestVideoCommandTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/digest-video", __dir__)

  def run_script(*args)
    Open3.capture3(SCRIPT, *args)
  end

  def test_tiktok_and_instagram_are_not_built_yet
    _out, err, status = run_script("https://www.tiktok.com/@a/video/1")
    refute status.success?
    assert_includes err, "not built yet: download-tiktok"
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
