# frozen_string_literal: true

# Tests for bin/lib/session_markers.rb — the marker READS bin/atomic-event and
# bin/atomic-capture-hook share (formerly byte-identical private copies).
# Best-effort contract: every failure degrades to nil, never raises.
#   ruby -Itest test/lib/session_markers_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"

require File.expand_path("../../bin/lib/session_markers", __dir__)

class SessionMarkersTest < Minitest::Test
  # ── [unit] read_context_marker ───────────────────────────────────────────────

  def test_unit_context_marker_reads_from_the_cwd
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), JSON.generate("task" => "t-1"))
      assert_equal({ "task" => "t-1" }, SessionMarkers.read_context_marker(dir))
    end
  end

  def test_unit_context_marker_walks_up_to_the_nearest_marker
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), JSON.generate("task" => "root"))
      nested = File.join(dir, "app", "models")
      FileUtils.mkdir_p(nested)
      assert_equal({ "task" => "root" }, SessionMarkers.read_context_marker(nested),
                   "a tool running in a subdir still resolves the worktree's marker")
    end
  end

  def test_unit_context_marker_is_nil_when_absent_or_blank_cwd
    Dir.mktmpdir { |dir| assert_nil SessionMarkers.read_context_marker(dir) }
    assert_nil SessionMarkers.read_context_marker(nil)
    assert_nil SessionMarkers.read_context_marker("   ")
  end

  def test_unit_context_marker_is_nil_on_invalid_json
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), "{nope")
      assert_nil SessionMarkers.read_context_marker(dir), "telemetry must never raise on a corrupt marker"
    end
  end

  # ── [unit] read_session_marker ───────────────────────────────────────────────

  def test_unit_session_marker_reads_the_per_session_file
    Dir.mktmpdir do |proj|
      write_session_marker(proj, "sess-1", "feature" => "f-1")
      assert_equal({ "feature" => "f-1" }, SessionMarkers.read_session_marker("sess-1", proj))
    end
  end

  def test_unit_session_marker_sanitizes_the_session_id
    Dir.mktmpdir do |proj|
      write_session_marker(proj, "abc123", "x" => 1)
      assert_equal({ "x" => 1 }, SessionMarkers.read_session_marker("abc/123", proj),
                   "path separators are stripped, never traversed")
    end
  end

  def test_unit_session_marker_is_nil_for_blank_id_or_missing_file
    Dir.mktmpdir do |proj|
      assert_nil SessionMarkers.read_session_marker("", proj)
      assert_nil SessionMarkers.read_session_marker(nil, proj)
      assert_nil SessionMarkers.read_session_marker("no-such", proj)
    end
  end

  private

  def write_session_marker(projects_dir, session_id, attrs)
    dir = File.join(projects_dir, ".agents", "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{session_id}.json"), JSON.generate(attrs))
  end
end
