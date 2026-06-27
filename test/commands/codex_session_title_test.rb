# frozen_string_literal: true

require "minitest/autorun"
require "json"
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

  def run_script(env = {}, stdin_data = "")
    Open3.capture3(
      {
        "CODEX_THREAD_ID" => "thread-123",
        "CODEX_STATE_DB" => @db,
        "SESSION_KICKOFF" => @kickoff,
        "CLAUDE_PROJECTS_DIR" => @tmp,
        "CODEX_SESSION_TITLE_RETRY_DELAYS" => "none"
      }.merge(env),
      SCRIPT,
      chdir: @tmp,
      stdin_data: stdin_data
    )
  end

  def calls
    File.exist?(@calls) ? File.read(@calls).lines.map(&:strip) : []
  end

  def assert_hook_context(out, marker)
    payload = JSON.parse(out)
    hook_output = payload.fetch("hookSpecificOutput")

    assert_equal "SessionStart", hook_output.fetch("hookEventName")
    assert_includes hook_output.fetch("additionalContext"), marker
    assert_includes hook_output.fetch("additionalContext"), "session identity"
  end

  def test_updates_codex_thread_title_from_session_marker
    marker = "🔥 Arcanine · mcritchie-studio"
    out, err, status = run_script("KICKOFF_MARKER" => marker)

    assert status.success?, err
    assert_hook_context out, marker
    assert_equal ["called"], calls
    assert_equal marker, title_for("thread-123")
  end

  def test_reads_session_id_from_session_start_payload
    marker = "🐲 Dragonair · mcritchie-studio"
    out, err, status = run_script(
      {
        "CODEX_THREAD_ID" => nil,
        "KICKOFF_MARKER" => marker
      },
      JSON.generate({ "session_id" => "thread-123", "source" => "startup" })
    )

    assert status.success?, err
    assert_hook_context out, marker
    assert_equal ["called"], calls
    assert_equal marker, title_for("thread-123")
  end

  def test_session_start_payload_wins_over_inherited_thread_id
    marker = "🐲 Dragonair · mcritchie-studio"
    out, err, status = run_script(
      {
        "CODEX_THREAD_ID" => "parent-thread",
        "KICKOFF_MARKER" => marker
      },
      JSON.generate({ "session_id" => "thread-123", "source" => "startup" })
    )

    assert status.success?, err
    assert_hook_context out, marker
    assert_equal ["called"], calls
    assert_equal marker, title_for("thread-123")
  end

  def test_retries_title_update_after_thread_row_appears
    marker = "🐲 Dragonair · mcritchie-studio"
    out, err, status = run_script(
      {
        "CODEX_THREAD_ID" => nil,
        "KICKOFF_MARKER" => marker,
        "CODEX_SESSION_TITLE_RETRY_DELAYS" => "0.1 0.2"
      },
      JSON.generate({ "session_id" => "late-thread", "source" => "startup" })
    )

    assert status.success?, err
    assert_hook_context out, marker

    sqlite(%(INSERT INTO threads (id, title) VALUES ('late-thread', 'late-thread');))
    sleep 0.35

    assert_equal marker, title_for("late-thread")
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

    out, err, status = run_script("KICKOFF_MARKER" => "🔥 Arcanine · mcritchie-studio")

    assert status.success?, err
    assert_empty calls
    marker = "🍃🍄 Bulbasaur · mcritchie-studio · codex-mascot-kickoff"
    assert_hook_context out, marker
    assert_equal marker, title_for("thread-123")
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

    out, err, status = run_script("KICKOFF_MARKER" => "🔥 Arcanine · mcritchie-studio")

    assert status.success?, err
    assert_empty calls
    marker = "🧪 Jasper · mcritchie-studio"
    assert_hook_context out, marker
    assert_equal marker, title_for("thread-123")
  end

  def test_quotes_marker_safely_for_sqlite
    marker = "⚡ Farfetch'd · mcritchie-studio"
    out, err, status = run_script("KICKOFF_MARKER" => marker)

    assert status.success?, err
    assert_hook_context out, marker
    assert_equal marker, title_for("thread-123")
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
