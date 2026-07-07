# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

class AgentMarkerTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "agent-marker")

  def setup
    @tmp = Dir.mktmpdir("agent-marker")
    @kickoff = File.join(@tmp, "session-kickoff")
    @calls = File.join(@tmp, "calls.log")
    File.write(@kickoff, <<~BASH)
      #!/usr/bin/env bash
      printf '%s\\n' "${CODEX_THREAD_ID:-missing}" >> "#{@calls}"
      [ -n "${KICKOFF_FAIL:-}" ] && exit 1
      [ -n "${CODEX_THREAD_ID:-}" ] || exit 1
      printf '%s\\n' "${KICKOFF_MARKER:-🍃 Bulbasaur · mcritchie-studio}"
    BASH
    FileUtils.chmod("+x", @kickoff)
  end

  def teardown
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def run_marker(*args, env: {}, chdir: @tmp)
    default_env = {
      "CLAUDE_PROJECTS_DIR" => @tmp,
      "SESSION_KICKOFF" => @kickoff,
      # Neutralize ambient agent-session vars so the test fully controls the
      # marker subprocess env. A live Claude Code session exports
      # CLAUDE_CODE_SESSION_ID, which Open3.capture3 would otherwise leak through
      # its env-merge and let bin/agent-marker prefer over our CODEX_THREAD_ID.
      "CLAUDE_CODE_SESSION_ID" => nil,
      "CODEX_THREAD_ID" => "thread-123"
    }
    Open3.capture3(default_env.merge(env), SCRIPT, *args, chdir: chdir)
  end

  def calls
    File.exist?(@calls) ? File.read(@calls).lines.map(&:strip) : []
  end

  def write_session(id, data)
    dir = File.join(@tmp, ".agents", "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{id}.json"), JSON.pretty_generate(data))
  end

  def test_current_prefers_worktree_context
    child = File.join(@tmp, "nested", "child")
    FileUtils.mkdir_p(child)
    File.write(File.join(@tmp, ".agent-context.json"), JSON.pretty_generate(
      "mascot" => "haunter",
      "mascot_emoji" => "👻🍄",
      "app" => "rolio",
      "worktree_slug" => "rolio-demo-polish-rehearsal"
    ))
    write_session("thread-123", "mascot" => "rattata", "app" => "mcritchie-studio")

    out, err, status = run_marker("current", "--no-kickoff", chdir: child)

    assert status.success?, err
    assert_equal "👻🍄 Haunter · rolio · rolio-demo-polish-rehearsal", out.strip
    assert_empty calls
  end

  def test_current_reads_session_marker_before_kickoff
    write_session("thread-123",
      "mascot" => "rattata",
      "mascot_emoji" => "🔶",
      "app" => "mcritchie-studio",
      "worktree_slug" => "tasks-button-deployments")

    out, err, status = run_marker("current")

    assert status.success?, err
    assert_equal "🔶 Rattata · mcritchie-studio · tasks-button-deployments", out.strip
    assert_empty calls
  end

  def test_current_adds_shiny_sparkle_to_marker_title
    write_session("thread-123",
      "mascot" => "rattata",
      "mascot_emoji" => "🔶",
      "mascot_shiny" => true,
      "app" => "mcritchie-studio",
      "worktree_slug" => "tasks-button-deployments")

    out, err, status = run_marker("current")

    assert status.success?, err
    assert_equal "🔶✨ Rattata · mcritchie-studio · tasks-button-deployments", out.strip
    assert_empty calls
  end

  def test_current_normalizes_legacy_prefixed_shiny_marker
    write_session("thread-123",
      "mascot" => "rattata",
      "mascot_emoji" => "✨🔶",
      "app" => "mcritchie-studio")

    out, err, status = run_marker("current")

    assert status.success?, err
    assert_equal "🔶✨ Rattata · mcritchie-studio", out.strip
  end

  def test_current_explicit_false_clears_legacy_shiny_marker
    write_session("thread-123",
      "mascot" => "rattata",
      "mascot_emoji" => "🔶✨",
      "mascot_shiny" => false,
      "app" => "mcritchie-studio")

    out, err, status = run_marker("current")

    assert status.success?, err
    assert_equal "🔶 Rattata · mcritchie-studio", out.strip
  end

  def test_current_falls_back_to_session_kickoff
    out, err, status = run_marker("current", "--session-id", "fresh-thread", env: { "CODEX_THREAD_ID" => nil })

    assert status.success?, err
    assert_equal "🍃 Bulbasaur · mcritchie-studio", out.strip
    assert_equal ["fresh-thread"], calls
  end

  def test_current_json_reports_source
    write_session("thread-123", "mascot" => "Jasper", "mascot_emoji" => "🧪", "app" => "mcritchie-studio")

    out, err, status = run_marker("current", "--format", "json")

    assert status.success?, err
    payload = JSON.parse(out)
    assert_equal "🧪 Jasper · mcritchie-studio", payload.fetch("title")
    assert_equal "session", payload.fetch("source")
    assert_equal "thread-123", payload.fetch("sessionId")
    assert_match(%r{\.agents/sessions/thread-123\.json\z}, payload.fetch("sourcePath"))
  end

  def test_current_no_kickoff_allows_empty_marker
    out, err, status = run_marker("current", "--no-kickoff", env: { "CODEX_THREAD_ID" => nil })

    assert status.success?, err
    assert_empty out
    assert_empty calls
  end
end
