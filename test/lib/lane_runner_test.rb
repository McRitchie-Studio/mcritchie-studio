# frozen_string_literal: true

# Unit tests for bin/lib/lane_runner.rb — one pre-flight lane in its own process
# group, bounded by a ceiling, never left behind.
#
#   ruby -Itest test/lib/lane_runner_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "timeout"
require_relative "../../bin/lib/lane_runner"

class LaneRunnerTest < Minitest::Test
  def test_a_green_lane_completes_ok
    result = LaneRunner.run({}, "true", chdir: Dir.tmpdir)

    assert result.ok
    assert_equal :completed, result.outcome
    refute result.timeout?
    refute result.unlaunchable?
  end

  def test_a_red_lane_completes_not_ok
    result = LaneRunner.run({}, "exit 3", chdir: Dir.tmpdir)

    refute result.ok
    assert_equal :completed, result.outcome
  end

  def test_the_lane_sees_the_env_and_the_cwd_it_was_given
    Dir.mktmpdir do |dir|
      result = LaneRunner.run({ "LANE_PROBE" => "yes" }, 'test "$LANE_PROBE" = yes && test "$(pwd)" = "$LANE_DIR"',
                              chdir: dir) # LANE_DIR unset → fails
      refute result.ok

      result = LaneRunner.run({ "LANE_PROBE" => "yes", "LANE_DIR" => File.realpath(dir) },
                              'test "$LANE_PROBE" = yes && test "$(pwd -P)" = "$LANE_DIR"', chdir: dir)
      assert result.ok
    end
  end

  def test_a_command_that_cannot_launch_is_unlaunchable_not_red
    result = LaneRunner.run({}, ["/nonexistent/runner", "x"].join(" "), chdir: Dir.tmpdir)

    # A shell string fails inside the shell (exit 127) — still completed. Only a
    # spawn that raises is :unlaunchable; drive that shape with an argv-less
    # absolute path the shell is not involved in.
    refute result.ok
    direct = LaneRunner.run({}, "/nonexistent/runner", chdir: Dir.tmpdir)
    refute direct.ok
    assert direct.unlaunchable?
    assert_match(%r{/nonexistent/runner}, direct.detail)
  end

  def test_a_lane_that_outruns_its_ceiling_is_a_timeout_and_its_group_is_reaped
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "child.pid")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = LaneRunner.run({}, "sh -c 'echo $$ > #{marker}; sleep 30' & echo $! > #{marker}.leader; wait",
                              chdir: dir, timeout: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      refute result.ok
      assert result.timeout?, "no verdict inside the ceiling is a TIMEOUT, never a red suite"
      assert_operator elapsed, :<, 10, "the ceiling must actually cut the lane short"

      leader = File.read("#{marker}.leader").to_i
      # The grandchild was in the lane's process group; a group kill reaches it.
      Timeout.timeout(5) do
        sleep 0.1 while process_alive?(leader)
      end
      refute process_alive?(leader), "the lane's whole process group must be reaped on timeout"
    end
  end

  def test_the_timeout_report_never_reads_as_a_test_failure
    hung = { "spine" => LaneRunner::Result.new(ok: false, outcome: :timeout, detail: "no verdict after 1s") }
    lines = LaneRunner.timeout_report(hung, ceiling: 1, tool: "fast-check", env_var: "FAST_CHECK_LANE_TIMEOUT")

    assert_match(/HUNG: spine/, lines.first)
    assert_match(/NOT a red suite/, lines.first)
    refute_match(/lane\(s\) RED/, lines.join("\n"))
    assert_match(/FAST_CHECK_LANE_TIMEOUT/, lines.last)
  end

  def test_signal_group_refuses_the_unsignalable_numbers
    refute LaneRunner.signal_group(0, "TERM")
    refute LaneRunner.signal_group(1, "TERM")
    refute LaneRunner.signal_group(Process.getpgrp, "TERM"), "never our own group"
    refute LaneRunner.signal_group(Process.pid, "TERM"), "never our own pid"
    refute LaneRunner.signal_group(nil, "TERM")
  end

  private

  def process_alive?(pid)
    return false unless pid.positive?

    Process.kill(0, pid)
    # A zombie still answers kill(0); read the state off ps.
    state = `ps -o state= -p #{pid}`.strip
    !state.empty? && !state.start_with?("Z")
  rescue Errno::ESRCH
    false
  end
end
