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
  # pgroup: true moves the child out of the caller's group, so a Ctrl-C or a
  # SIGTERM to the caller no longer reaches it: the caller must kill it on the way out.
  def test_unit_a_signal_to_the_caller_takes_the_child_group_with_it
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "survived")
      lib = File.expand_path("../../bin/lib/bounded_command", __dir__)
      script = %(require #{lib.inspect}; BoundedCommand.run({}, ["sh", "-c", "(sleep 1; touch #{marker}) & exec sleep 600"], deadline: 60, pgroup: true))
      caller_pid = Process.spawn("ruby", "-e", script, out: File::NULL, err: File::NULL)
      sleep 0.4
      Process.kill(:TERM, caller_pid)
      Process.wait(caller_pid)
      sleep 1.3
      refute File.exist?(marker), "the child's group outlived a signal to its caller"
    end
  end

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

  # `op` ignores SIGALRM (2026-10-27: a perl `alarm` wrapper failed to kill a hung
  # `op read`), so a bound that rests on SIGALRM — Timeout.timeout, `alarm` — does
  # not bound it. SIGKILL cannot be trapped.
  def test_unit_a_hung_child_that_ignores_sigalrm_is_killed_within_its_deadline
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "outlived")
      script = "trap '' ALRM TERM INT HUP; (trap '' ALRM TERM; sleep 2; touch #{marker}) & " \
               "kill -ALRM $$; printf ignored; sleep 600"
      result, seconds = elapsed { BoundedCommand.capture2e({}, "sh", "-c", script, deadline: 0.5) }
      sleep 2.5

      assert result.last.timed_out?
      refute result.last.success?
      assert_equal "ignored", result.first, "the child shrugged off its own SIGALRM and kept running"
      assert_equal 9, result.last.termsig
      assert_operator seconds, :<, 3
      refute File.exist?(marker), "the whole group goes: a grandchild that also ignores SIGALRM dies with it"
    end
  end

  def test_unit_capture2e_merges_both_streams_and_answers_like_a_status
    out, status = BoundedCommand.capture2e({}, "sh", "-c", "printf out; printf err >&2; exit 4", deadline: 5)

    assert_equal "outerr", out
    refute status.success?
    assert_equal 4, status.exitstatus
    assert_nil status.termsig
  end

  def test_unit_capture3_keeps_stderr_apart
    out, err, status = BoundedCommand.capture3({ "W" => "x" }, "sh", "-c", "printf \"$W\"; printf oops >&2", deadline: 5)

    assert_equal "x", out
    assert_equal "oops", err
    assert status.success?
  end

  def test_unit_capture_helpers_give_the_child_no_terminal_to_read
    out, status = BoundedCommand.capture2e({}, "sh", "-c", "read line; printf \"[$line]\"", deadline: 5)

    assert_equal "[]", out, "stdin is /dev/null: a read answers EOF at once instead of stopping on SIGTTIN"
    refute status.timed_out?
  end

  def test_unit_stream_copies_each_chunk_as_it_arrives
    reader, writer = IO.pipe
    result = BoundedCommand.run({}, ["sh", "-c", "printf a; sleep 0.2; printf b"], deadline: 5, stream: writer)
    writer.close

    assert_equal "ab", result.out
    assert_equal "ab", reader.read
  ensure
    reader&.close
  end
end
