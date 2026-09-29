# frozen_string_literal: true

require "minitest/autorun"
require "open3"

# [integration] bin/find-clips as a process, on paths that make no network call.
class FindClipsCommandTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/find-clips", __dir__)

  def test_needs_exactly_one_slug
    _out, err, status = Open3.capture3(SCRIPT)
    refute status.success?
    assert_includes err, "a music video slug is required"
    _out, err, status = Open3.capture3(SCRIPT, "a", "b")
    refute status.success?
    assert_includes err, "exactly one slug"
  end

  def test_a_missing_source_file_stops_before_any_call
    _out, err, status = Open3.capture3(SCRIPT, "steve-aoki-night-call", "--source", "/nonexistent/x.mp4")
    refute status.success?
    assert_includes err, "no such file"
  end

  def test_help_names_the_production_flag
    out, _err, status = Open3.capture3(SCRIPT, "--help")
    assert status.success?
    assert_includes out, "--production"
    assert_includes out, "--dry-run"
  end
end
