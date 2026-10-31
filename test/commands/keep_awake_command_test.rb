# frozen_string_literal: true

# bin/keep-awake end to end: the real CLI and a real supervisor process, with
# caffeinate and the notifier replaced by recording stubs and the menu-bar
# indicator switched off. Nothing here holds the real Mac awake, and teardown
# kills anything a failed assertion left running.
#
#   bin/rails test test/commands/keep_awake_command_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"
require "timeout"
require_relative "../support/session_env"

class KeepAwakeCommandTest < Minitest::Test
  BIN = File.expand_path("../../bin/keep-awake", __dir__)

  def setup
    @root = Dir.mktmpdir("keep-awake-cli")
    @state = File.join(@root, "state")
    @caffeinate_log = File.join(@root, "caffeinate.log")
    @notify_log = File.join(@root, "notify.log")
    @caffeinate = stub("caffeinate", <<~SH)
      echo "$$ $*" >> #{@caffeinate_log}
      while kill -0 $PPID 2>/dev/null; do sleep 0.1; done
    SH
    @notifier = stub("notify", %(printf '%s|%s\\n' "$1" "$2" >> #{@notify_log}))
  end

  def teardown
    pids = []
    pids << supervisor_pid
    pids.concat(caffeinate_pids)
    pids.compact.each do |pid|
      Process.kill("KILL", pid)
    rescue SystemCallError
      nil
    end
    FileUtils.rm_rf(@root)
  end

  def stub(name, body)
    path = File.join(@root, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def env
    SessionEnv.neutralized(
      "MCR_KEEP_AWAKE_DIR" => @state,
      "MCR_KEEP_AWAKE_CAFFEINATE" => @caffeinate,
      "MCR_KEEP_AWAKE_NOTIFIER" => @notifier,
      "MCR_KEEP_AWAKE_INDICATOR" => "0",
      "MCR_KEEP_AWAKE_TICK" => "0.2",
      "TASK_USAGE_SANDBOX" => "1"
    )
  end

  def run_cli(*args, stdout_only: false)
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [stdout_only ? out : out + err, status.exitstatus]
  end

  def state
    JSON.parse(File.read(File.join(@state, "state.json")))
  rescue Errno::ENOENT
    {}
  end

  def supervisor_pid
    state.dig("supervisor", "pid")
  end

  def caffeinate_pids
    return [] unless File.exist?(@caffeinate_log)

    File.readlines(@caffeinate_log).map { |l| l.split.first.to_i }
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_for(seconds = 10)
    Timeout.timeout(seconds) { sleep 0.05 until yield }
  end

  def notifications
    File.exist?(@notify_log) ? File.read(@notify_log) : ""
  end

  def test_integration_status_with_no_hold_exits_one
    out, code = run_cli("status")

    assert_equal 1, code
    assert_match(/not held/, out)
  end

  def test_integration_start_join_stop_lifecycle
    out, code = run_cli("start", "--by", "pokemon-a", "--reason", "overnight release")
    assert_equal 0, code, out
    assert_match(/Started the hold for pokemon-a/, out)

    wait_for { caffeinate_pids.any? }
    assert_match(/-dims -w #{supervisor_pid}/, File.read(@caffeinate_log), "caffeinate must hold the display too")

    out, code = run_cli("status")
    assert_equal 0, code, out
    assert_match(/HELD/, out)
    assert_match(/pokemon-a .*overnight release/, out)

    out, code = run_cli("start", "--by", "carl-b", "--reason", "long review")
    assert_equal 0, code, out
    assert_match(/Joined/, out)
    sleep 0.5
    assert_equal 1, caffeinate_pids.size, "a join must not start a second caffeinate"

    json, code = run_cli("status", "--json", stdout_only: true)
    assert_equal 0, code
    assert_equal %w[pokemon-a carl-b], JSON.parse(json)["holders"].map { |h| h["by"] }

    out, = run_cli("stop", "--by", "pokemon-a")
    assert_match(/1 holder\(s\) still hold/, out)
    sleep 0.5
    assert alive?(caffeinate_pids.first), "the hold continues while carl-b holds it"

    supervisor = supervisor_pid
    out, = run_cli("stop", "--by", "carl-b")
    assert_match(/hold ends/, out)
    wait_for { !alive?(supervisor) && !alive?(caffeinate_pids.first) }

    _, code = run_cli("status")
    assert_equal 1, code
    assert_match(/Started by pokemon-a/, notifications)
    assert_match(/may sleep again/, notifications)

    events = run_cli("history", stdout_only: true).first.lines.map { |l| l.split("\t")[1] }
    assert_equal %w[start join release release end], events
  end

  def test_integration_an_unrenewed_lease_lapses_and_releases_the_mac
    _, code = run_cli("start", "--by", "pokemon-a", "--reason", "short", "--for", "1s")
    assert_equal 0, code
    wait_for { caffeinate_pids.any? }
    supervisor = supervisor_pid

    wait_for { !alive?(supervisor) }
    wait_for { !alive?(caffeinate_pids.first) }
    assert_match(/pokemon-a's hold lapsed/, notifications)
    _, code = run_cli("status")
    assert_equal 1, code
  end

  def test_integration_renew_without_a_lease_exits_one
    out, code = run_cli("renew", "--by", "nobody")

    assert_equal 1, code
    assert_match(/no live lease/, out)
  end

  def test_integration_start_without_reason_is_a_usage_error
    out, code = run_cli("start", "--by", "pokemon-a")

    assert_equal 2, code
    assert_match(/--reason is required/, out)
    assert_empty caffeinate_pids
  end
end
