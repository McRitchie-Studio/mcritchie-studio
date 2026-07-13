# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class SessionKickoffTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "session-kickoff")

  def setup
    @tmp = Dir.mktmpdir("session-kickoff")
    @calls = File.join(@tmp, "calls.log")
    @task = File.join(@tmp, "task")
    File.write(@task, <<~BASH)
      #!/usr/bin/env bash
      printf '%s\\n' "$*" >> "#{@calls}"
      [ -n "${TASK_EMPTY_OUTPUT:-}" ] && exit 0
      echo "FIRE Arcanine - mcritchie-studio"
    BASH
    FileUtils.chmod("+x", @task)
  end

  def teardown
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def run_kickoff(*args, env: {})
    # Deliberate: kickoff resolves its session from CODEX_THREAD_ID. SessionEnv
    # (test/support/session_env.rb) unsets the ambient session vars, so this
    # override — and whatever a test passes in `env` — is the only session the
    # child sees.
    Open3.capture3(
      SessionEnv.neutralized({ "TASK_BIN" => @task, "CODEX_THREAD_ID" => "session-123" }.merge(env)),
      SCRIPT,
      *args
    )
  end

  def calls
    File.exist?(@calls) ? File.read(@calls).lines.map(&:strip) : []
  end

  def test_default_prints_the_session_pokemon
    out, err, status = run_kickoff

    assert status.success?, err
    assert_equal ["session-mascot --print"], calls
    assert_equal "FIRE Arcanine - mcritchie-studio", out.strip
  end

  def test_positional_persona_switches_the_visible_marker
    _out, err, status = run_kickoff("jasper")

    assert status.success?, err
    assert_equal ["session-mascot --persona jasper --print"], calls
  end

  def test_pokemon_alias_clears_the_persona
    _out, err, status = run_kickoff("pokemon")

    assert status.success?, err
    assert_equal ["session-mascot --persona none --print"], calls
  end

  def test_errors_clearly_without_an_agent_session_id
    _out, err, status = run_kickoff(env: { "CODEX_THREAD_ID" => nil, "CLAUDE_CODE_SESSION_ID" => nil })

    refute status.success?
    assert_equal 64, status.exitstatus
    assert_match(/no Claude\/Codex session id found/, err)
    assert_empty calls
  end

  def test_errors_when_task_does_not_print_a_marker
    _out, err, status = run_kickoff(env: { "TASK_EMPTY_OUTPUT" => "1" })

    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/no marker printed/, err)
    assert_equal ["session-mascot --print"], calls
  end
end
