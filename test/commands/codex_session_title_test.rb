# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class CodexSessionTitleTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "codex-session-title")

  def setup
    @tmp = Dir.mktmpdir("codex-session-title")
    @db = File.join(@tmp, "state_5.sqlite")
    @kickoff = File.join(@tmp, "session-kickoff")
    @calls = File.join(@tmp, "calls.log")
    File.write(@kickoff, <<~BASH)
      #!/usr/bin/env bash
      printf 'called\\n' >> "#{@calls}"
      [ -n "${KICKOFF_FAIL:-}" ] && exit 1
      printf '%s\\n' "${KICKOFF_MARKER:-🍃 Bulbasaur · mcritchie-studio}"
    BASH
    FileUtils.chmod("+x", @kickoff)
    sqlite(%(CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL);))
    sqlite(%(INSERT INTO threads (id, title) VALUES ('thread-123', 'thread-123');))
  end

  def teardown
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def sqlite(sql)
    system("sqlite3", @db, sql, exception: true)
  end

  def title_for(id)
    IO.popen(["sqlite3", @db, "SELECT title FROM threads WHERE id = '#{id}';"], &:read).strip
  end

  def run_script(env = {})
    Open3.capture3(
      {
        "CODEX_THREAD_ID" => "thread-123",
        "CODEX_STATE_DB" => @db,
        "SESSION_KICKOFF" => @kickoff,
        "CLAUDE_PROJECTS_DIR" => @tmp
      }.merge(env),
      SCRIPT,
      chdir: @tmp
    )
  end

  def calls
    File.exist?(@calls) ? File.read(@calls).lines.map(&:strip) : []
  end

  def test_updates_codex_thread_title_from_session_marker
    out, err, status = run_script("KICKOFF_MARKER" => "🔥 Arcanine · mcritchie-studio")

    assert status.success?, err
    assert_empty out
    assert_equal ["called"], calls
    assert_equal "🔥 Arcanine · mcritchie-studio", title_for("thread-123")
  end

  def test_prefers_worktree_context_marker_when_present
    File.write(File.join(@tmp, ".agent-context.json"), <<~JSON)
      {
        "mascot": "bulbasaur",
        "mascot_emoji": "🍃🍄",
        "app": "mcritchie-studio",
        "worktree_slug": "codex-mascot-kickoff"
      }
    JSON

    _out, err, status = run_script("KICKOFF_MARKER" => "🔥 Arcanine · mcritchie-studio")

    assert status.success?, err
    assert_empty calls
    assert_equal "🍃🍄 Bulbasaur · mcritchie-studio · codex-mascot-kickoff", title_for("thread-123")
  end

  def test_uses_existing_session_marker_before_calling_kickoff
    FileUtils.mkdir_p(File.join(@tmp, ".agents", "sessions"))
    File.write(File.join(@tmp, ".agents", "sessions", "thread-123.json"), <<~JSON)
      {
        "mascot": "Jasper",
        "mascot_emoji": "🧪",
        "app": "mcritchie-studio"
      }
    JSON

    _out, err, status = run_script("KICKOFF_MARKER" => "🔥 Arcanine · mcritchie-studio")

    assert status.success?, err
    assert_empty calls
    assert_equal "🧪 Jasper · mcritchie-studio", title_for("thread-123")
  end

  def test_quotes_marker_safely_for_sqlite
    _out, err, status = run_script("KICKOFF_MARKER" => "⚡ Farfetch'd · mcritchie-studio")

    assert status.success?, err
    assert_equal "⚡ Farfetch'd · mcritchie-studio", title_for("thread-123")
  end

  def test_exits_zero_without_codex_thread_id
    _out, err, status = run_script("CODEX_THREAD_ID" => nil)

    assert status.success?, err
    assert_empty calls
    assert_equal "thread-123", title_for("thread-123")
  end

  def test_kickoff_failure_does_not_break_session_start
    _out, err, status = run_script("KICKOFF_FAIL" => "1")

    assert status.success?, err
    assert_equal ["called"], calls
    assert_equal "thread-123", title_for("thread-123")
  end
end
