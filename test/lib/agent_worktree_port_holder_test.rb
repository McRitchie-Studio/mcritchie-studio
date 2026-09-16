# frozen_string_literal: true

# bin/agent-worktree's PORT is a hint about which process is a desk's server, never its
# name. Two defects followed from treating it as a name, and their symptoms showed up on
# CI together (hub release-push run 35092204659, job `rails (2)`, 2026-09-16):
#
#   * stop_generic_rails sent SIGTERM to whatever pid `lsof` found LISTENING on the desk's
#     APP_PORT. The command-test fixture desks use 39999, which sits inside Linux's default
#     ephemeral range (32768-60999), and every AgentWorktreeCommandTest starts an in-process
#     DeskLedgerSink on port 0. A test worker that holds 39999 is therefore signalled by any
#     concurrent teardown test: Minitest passes SignalException through, the worker dies
#     mid-test, and Rails records `RuntimeError: result not reported`. Reproduced locally,
#     with the CI log's exact fingerprints; the CI log itself cannot name the pid.
#   * the health probe read the same real port, so a concurrent test read `port-busy`
#     where it asserted `down`.
#
# This file pins the decisions in-process. The end-to-end proof, a real signal to a real
# process through `remove --yes`, lives in test/commands/agent_worktree_port_isolation_test.rb.
#   ruby -Itest test/lib/agent_worktree_port_holder_test.rb
require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../support/session_env"

class AgentWorktreePortHolderTest < Minitest::Test
  BIN = File.expand_path("../../bin/agent-worktree", __dir__)

  def setup
    @tmp = File.realpath(Dir.mktmpdir("agent-worktree-port-holder"))
    @desk = File.join(@tmp, "desk")
    FileUtils.mkdir_p(@desk)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # Loads the script in a clean child (its dispatch is guarded by $PROGRAM_NAME), with
  # Process.kill recorded instead of delivered, so no test here can signal anything.
  def run_in_script(body, env: {}, chdir: @tmp)
    script = <<~RUBY
      load #{BIN.inspect}
      KILLS = []
      module Process
        def self.kill(signal, pid) = (KILLS << [signal.to_s, pid.to_i]; 1)
      end
      #{body}
    RUBY
    out, err, status = Open3.capture3(SessionEnv.neutralized.merge(env), RbConfig.ruby, "-e", script, chdir: chdir)
    assert status.success?, "script child failed (exit #{status.exitstatus.inspect})\n#{out}\n#{err}"
    [out.strip, err]
  end

  # [unit] THE CI DEATH'S SHAPE. The pid on the port is a sibling test worker, rooted
  # anywhere but the desk. Stopping the desk must not signal it.
  def test_unit_stop_leaves_a_foreign_port_holder_running
    out, err = run_in_script(<<~RUBY)
      def port_pid(_port) = "4242"
      def process_cwd(_pid) = "/home/runner/work/mcritchie-studio/mcritchie-studio"
      stop_generic_rails(#{@desk.inspect}, "39999")
      print KILLS.inspect
    RUBY

    assert_equal "[]", out.lines.last, "a process not rooted in the desk is not the desk's server"
    assert_includes err, "port 39999 is held by pid 4242"
    assert_includes err, "not this desk's stack"
  end

  # [unit] An UNREADABLE cwd is not a match. File.expand_path("") is the CALLER's cwd, so
  # comparing expanded paths answers "ours" for any unreadable process whenever the script
  # runs from inside the desk. The child here runs with the desk as its cwd on purpose.
  def test_unit_stop_leaves_a_holder_with_an_unreadable_cwd_running_even_from_inside_the_desk
    out, err = run_in_script(<<~RUBY, chdir: @desk)
      def port_pid(_port) = "4242"
      def process_cwd(_pid) = ""
      stop_generic_rails(#{@desk.inspect}, "39999")
      print KILLS.inspect
    RUBY

    assert_equal "[]", out.lines.last
    assert_includes err, "cwd unreadable"
  end

  # [unit] THE CONTROL. Without it, a guard that never signals anything passes both tests
  # above while quietly orphaning every desk's server on teardown.
  def test_unit_stop_terminates_the_desks_own_server
    out, = run_in_script(<<~RUBY)
      def port_pid(_port) = "4242"
      def process_cwd(_pid) = #{@desk.inspect}
      stop_generic_rails(#{@desk.inspect}, "39999")
      print KILLS.inspect
    RUBY

    assert_includes out, "stopped web pid 4242 on port 39999"
    assert_equal '[["TERM", 4242]]', out.lines.last
  end

  # [unit] REAL PATHS, COMPARED WHOLE. A prefix check signals desk-bar's server when desk
  # stops; an unresolved one refuses the desk's own server reached through a symlink.
  def test_unit_desk_match_spares_a_sibling_and_follows_a_symlink
    sibling = FileUtils.mkdir_p("#{@desk}-bar").first
    link = File.join(@tmp, "link").tap { |path| File.symlink(@tmp, path) }
    out, = run_in_script(<<~RUBY)
      def port_pid(_port) = "4242"
      def process_cwd(_pid) = #{sibling.inspect}
      stop_generic_rails(#{@desk.inspect}, "39999")
      def port_pid(_port) = "5353"
      def process_cwd(_pid) = #{@desk.inspect}
      stop_generic_rails(#{File.join(link, "desk").inspect}, "39999")
      print KILLS.inspect
    RUBY

    assert_equal '[["TERM", 5353]]', out.lines.last, "spare pid 4242 (sibling); stop pid 5353 (desk via symlink)"
  end

  # [unit] The same guard on the STALE-PIDFILE branch: the pidfile's own pid is dead, so the
  # port holder is the only candidate, and it gets the same ownership check.
  def test_unit_a_stale_pidfile_does_not_license_signalling_a_foreign_holder
    pidfile = File.join(@desk, "tmp", "pids", "agent-web.pid")
    FileUtils.mkdir_p(File.dirname(pidfile))
    File.write(pidfile, "999999\n")

    out, err = run_in_script(<<~RUBY)
      def pid_alive?(_pid) = false
      def port_pid(_port) = "4242"
      def process_cwd(_pid) = "/somewhere/else"
      stop_generic_rails(#{@desk.inspect}, "39999")
      print KILLS.inspect
    RUBY

    assert_equal "[]", out.lines.last
    assert_includes err, "held by pid 4242"
    refute_path_exists pidfile, "the stale pidfile is still cleared"
  end

  # [unit] The shared ownership check keeps the adoption guard's answers, and gains the
  # unreadable-cwd refusal: `up` must not adopt a process it cannot see into either.
  def test_unit_own_stack_on_port_refuses_an_unreadable_cwd_from_inside_the_desk
    out, = run_in_script(<<~RUBY, chdir: @desk)
      def port_pid(_port) = "4242"
      def process_cwd(_pid) = ""
      print own_stack_on_port?(3020, #{@desk.inspect})
    RUBY

    assert_equal "false", out
  end

  # [unit] THE PORT READERS ARE SEAMS. A recording fake stands in for lsof and curl, and the
  # script must both ASK it (the argv it receives is the real lookup, byte for byte) and
  # BELIEVE it (its answers become the record's pid and /up code).
  def test_unit_port_reads_route_through_the_named_reader_seams
    log = File.join(@tmp, "reader-calls.log")
    lsof = write_fake(File.join(@tmp, "fake-lsof"), log, "7777")
    curl = write_fake(File.join(@tmp, "fake-curl"), log, "503")

    out, = run_in_script(<<~RUBY, env: { "AGENT_WORKTREE_LSOF_BIN" => lsof, "AGENT_WORKTREE_CURL_BIN" => curl })
      print [port_pid("39999"), http_code("39999"), port_listening?("39999")].inspect
    RUBY

    assert_equal '["7777", "503", true]', out
    calls = File.readlines(log, chomp: true)
    assert_includes calls, "fake-lsof -tiTCP:39999 -sTCP:LISTEN"
    assert_includes calls, "fake-lsof -nP -iTCP:39999 -sTCP:LISTEN"
    assert_includes calls, "fake-curl -sS -o /dev/null -m 2 -w %{http_code} http://localhost:39999/up"
  end

  # [unit] Unset or blank, the seams are the real binaries. A blank value must not become an
  # empty argv[0], which would raise instead of reading the port.
  def test_unit_blank_reader_seams_fall_back_to_the_real_binaries
    out, = run_in_script(<<~RUBY, env: { "AGENT_WORKTREE_LSOF_BIN" => " ", "AGENT_WORKTREE_CURL_BIN" => "" })
      print [lsof_bin, curl_bin].inspect
    RUBY

    assert_equal '["lsof", "curl"]', out
  end

  private

  # A reader that logs "<name> <argv>" and prints one fixed answer.
  def write_fake(path, log, answer)
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s %s\\n' "$(basename "$0")" "$*" >> #{log.inspect}
      printf '%s' #{answer.inspect}
    SH
    File.chmod(0o755, path)
    path
  end
end
