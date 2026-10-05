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
    assert_includes out, "--tile"
    assert_includes out, "overlapping chunks (25 s, 5 s overlap)"
  end

  def test_help_names_the_tiling_flags
    out, _err, status = Open3.capture3(SCRIPT, "--help")
    assert status.success?
    assert_includes out, "--chunk SECONDS"
    assert_includes out, "--overlap SECONDS"
  end

  def test_an_overlap_as_long_as_the_chunk_stops_before_any_call
    [%w[--chunk 15 --overlap 15], %w[--chunk 5 --overlap 9], %w[--overlap 25]].each do |flags|
      _out, err, status = Open3.capture3(SCRIPT, "a-slug", "--tile", *flags)
      refute status.success?
      assert_includes err, "find-clips: the overlap"
      assert_includes err, "must be shorter than the chunk"
    end
    _out, err, status = Open3.capture3(SCRIPT, "a-slug", "--tile", "--chunk", "0")
    refute status.success?
    assert_includes err, "find-clips: the chunk length must be whole milliseconds above zero"
    _out, err, status = Open3.capture3(SCRIPT, "a-slug", "--tile", "--chunk", "long")
    refute status.success?
    assert_includes err, "find-clips: invalid argument: --chunk long"
  end

  def test_the_tiling_flags_need_tile
    _out, err, status = Open3.capture3(SCRIPT, "a-slug", "--chunk", "15")
    refute status.success?
    assert_includes err, "find-clips: --chunk sets the tiling: pass --tile with it"
  end
end
