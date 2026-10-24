# frozen_string_literal: true

# [unit] BoundedCommand, the deadline under every 1Password read and the
# dispatcher's harness probe.
#
#   bin/rails test test/lib/bounded_command_test.rb
require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/bounded_command"

class BoundedCommandTest < Minitest::Test
  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def test_unit_a_child_that_answers_in_time_keeps_its_stdout_and_status
    result = BoundedCommand.run({ "WORD" => "hi" }, ["sh", "-c", "printf \"$WORD\"; exit 3"], deadline: 5)

    assert_equal "hi", result.out
    assert_equal 3, result.status.exitstatus
    refute result.timed_out?
    assert_equal 3, $?.exitstatus, "callers read $? after the call, as after IO.popen"
  end

  def test_unit_a_hung_child_is_killed_at_the_deadline
    result, seconds = elapsed { BoundedCommand.run({}, ["sh", "-c", "printf part; exec sleep 600"], deadline: 0.5) }

    assert result.timed_out?
    refute result.success?
    assert_equal "part", result.out, "what the child said before the deadline is kept"
    assert_equal 9, result.status.termsig, "SIGKILL, then reaped"
    assert_operator seconds, :<, 3
  end

  def test_unit_a_process_group_is_killed_whole
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "grandchild-lived")
      result = BoundedCommand.run({}, ["sh", "-c", "(sleep 1; touch #{marker}) & exec sleep 600"], deadline: 0.3, pgroup: true)
      sleep 1.5

      assert result.timed_out?
      refute File.exist?(marker), "pgroup: true kills the child's children too"
    end
  end

  # A grandchild that inherits stdout (a daemon started in the background)
  # must not hold the call open after the child itself has exited.
  def test_unit_a_grandchild_holding_stdout_does_not_stall_a_finished_child
    result, seconds = elapsed { BoundedCommand.run({}, ["sh", "-c", "(sleep 30 &); printf done"], deadline: 10) }

    refute result.timed_out?
    assert_equal "done", result.out
    assert_operator seconds, :<, 3
  end

  def test_unit_a_one_word_command_never_reaches_a_shell
    result = BoundedCommand.run({}, ["echo"], deadline: 5)
    assert result.success?
    assert_raises(Errno::ENOENT) { BoundedCommand.run({}, ["echo hi; true"], deadline: 5) }
  end

  def test_unit_a_missing_binary_raises_like_io_popen
    assert_raises(Errno::ENOENT) { BoundedCommand.run({}, ["/nonexistent/op", "read"], deadline: 1) }
  end
end
