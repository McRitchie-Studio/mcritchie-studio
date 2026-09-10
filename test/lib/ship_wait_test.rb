# frozen_string_literal: true

# [unit] The decision rules behind bin/ship-wait (bin/lib/ship_wait.rb).
#
# WHAT THESE ARE FOR, and why they are not "it waits" tests. A watcher test that
# asserts the watcher WAITS passes on a watcher that waits FOREVER — which is
# precisely the defect this family exists to kill (task ship-wait-has-no-primitive:
# `while pgrep -f "bin/ship <slug>"` can never be false, and an immortal watcher is
# indistinguishable from a slow job). So every test here pins a FIRING condition:
# the exact input on which the verdict must be terminal, and the exact input on
# which "ended" must NOT be read as "succeeded".
#
# Run directly:
#   ruby -Itest test/lib/ship_wait_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../support/session_env"
require_relative "../../bin/lib/ship_wait"

class ShipWaitTest < Minitest::Test
  SUCCESS = ShipWait::SUCCESS_LINE
  SENTINEL_OK = "#{ShipWait::SENTINEL_PREFIX}0"
  SENTINEL_BAD = "#{ShipWait::SENTINEL_PREFIX}1"

  def log(*lines) = "#{lines.join("\n")}\n"

  # --- the success line ------------------------------------------------------

  def test_succeeded_on_ships_own_read_back_line
    assert ShipWait.succeeded?(log("ship: 8/8 submit", SUCCESS))
  end

  def test_not_succeeded_while_the_line_is_absent
    refute ShipWait.succeeded?(log("ship: 6/8 CI wait — pending", "ship: 7/8 dor-check"))
  end

  # THE LINE IS MATCHED WHOLE, NOT AS A SUBSTRING. The same phrase appears in
  # bin/ship's header comment, in these docs, and in any log that quotes them —
  # a watcher that fires on its own documentation is the same class of bug as one
  # that greps its own command line.
  def test_a_quoted_mention_of_the_line_is_not_the_line
    quoted = log("ship: the final line is \"#{SUCCESS}\" — not yet printed")
    refute ShipWait.succeeded?(quoted)
    assert_equal :running, ShipWait.verdict(quoted)
  end

  # --- the sentinel ----------------------------------------------------------

  def test_sentinel_status_is_read_from_the_log
    assert_equal 0, ShipWait.sentinel_status(log("ship: done", SENTINEL_OK))
    assert_equal 1, ShipWait.sentinel_status(log("ship: boom", SENTINEL_BAD))
    assert_nil ShipWait.sentinel_status(log("ship: 3/8 push"))
  end

  def test_last_sentinel_wins
    assert_equal 1, ShipWait.sentinel_status(log(SENTINEL_OK, "ship: second run", SENTINEL_BAD))
  end

  def test_exited_is_the_sentinels_presence_not_its_value
    assert ShipWait.exited?(log(SENTINEL_OK))
    assert ShipWait.exited?(log(SENTINEL_BAD))
    refute ShipWait.exited?(log("ship: 5/8 record pr_url"))
  end

  # --- the verdict -----------------------------------------------------------

  def test_running_while_nothing_terminal_is_in_the_log
    assert_equal :running, ShipWait.verdict(log("ship: 6/8 CI wait — pending (120s)"), ended: false)
  end

  def test_succeeded_when_the_log_carries_the_line
    assert_equal :succeeded, ShipWait.verdict(log("ship: 8/8", SUCCESS, SENTINEL_OK), ended: true)
  end

  # THE CRUX. bin/ship EXITS 0 ON FAILURE, so a zero status is not a verdict.
  # Read the exit code here instead of the log and this is the test that reddens.
  def test_a_zero_exit_status_without_the_line_is_a_FAILURE
    text = log("ship: bin/dor-check refused — fix everything it flagged", SENTINEL_OK)
    assert_equal :failed, ShipWait.verdict(text, ended: true)
    assert_equal 0, ShipWait.sentinel_status(text), "the status really is 0 — the verdict must not come from it"
  end

  # And the mirror: a non-zero status AFTER the seam line is still a success,
  # because the seam line is the fact and the status is not.
  def test_the_line_outranks_a_nonzero_status
    assert_equal :succeeded, ShipWait.verdict(log(SUCCESS, SENTINEL_BAD), ended: true)
  end

  def test_ended_without_the_line_is_failed_even_with_no_sentinel
    # The `--pid` lane: the captured PID is gone, the log holds no sentinel.
    assert_equal :failed, ShipWait.verdict(log("ship: 4/8 open PR"), ended: true)
  end

  def test_a_sentinel_alone_ends_the_wait_without_any_pid
    # The attach-from-a-cold-session lane: no process, no PID, still terminal.
    assert_equal :failed, ShipWait.verdict(log("ship: 4/8 open PR", SENTINEL_BAD), ended: false)
  end

  # --- exit codes ------------------------------------------------------------

  def test_exit_codes_are_distinct_and_meaningful
    assert_equal 0, ShipWait.exit_code(:succeeded)
    assert_equal 1, ShipWait.exit_code(:failed)
    assert_equal 2, ShipWait.exit_code(:running)
    assert_equal [0, 1, 2, 3, 4].sort,
                 [ShipWait::EXIT_SUCCEEDED, ShipWait::EXIT_FAILED, ShipWait::EXIT_TIMEOUT,
                  ShipWait::EXIT_USAGE, ShipWait::EXIT_NO_LOG].sort,
                 "the caller branches on these; two states sharing a code is a silent merge"
  end

  # --- liveness, without a pattern -------------------------------------------

  def test_alive_for_this_very_process
    assert ShipWait.alive?(Process.pid)
  end

  def test_not_alive_for_a_reaped_child
    pid = Process.spawn("/bin/sh", "-c", "exit 0", out: File::NULL, err: File::NULL)
    Process.wait(pid)
    refute ShipWait.alive?(pid), "a reaped pid must read dead — this is the only liveness signal we have"
  end

  def test_not_alive_for_nonsense_pids
    refute ShipWait.alive?(0)
    refute ShipWait.alive?(-1)
    refute ShipWait.alive?(nil)
  end

  # --- reporting and paths ---------------------------------------------------

  def test_last_report_prefers_ships_own_line
    text = log("ship: 7/8 dor-check", "ship: bin/dor-check refused", "some trailing noise")
    assert_equal "ship: bin/dor-check refused", ShipWait.last_report(text)
  end

  def test_last_report_falls_back_to_the_last_line
    assert_equal "Killed: 9", ShipWait.last_report(log("building", "", "Killed: 9", ""))
  end

  def test_state_paths_are_namespaced_by_slug
    assert_equal "/s/ship-abc.log", ShipWait.log_path("/s", "abc")
    assert_equal "/s/ship-abc.pid", ShipWait.pid_path("/s", "abc")
    assert_equal "/s/ship-abc.log.prev", ShipWait.previous_log_path("/s", "abc")
  end

  def test_interval_is_floored_so_the_wait_cannot_spin
    assert_equal 1.0, ShipWait.clamp_interval(0)
    assert_equal 1.0, ShipWait.clamp_interval(0.01)
    assert_equal 30.0, ShipWait.clamp_interval(30)
  end
end
