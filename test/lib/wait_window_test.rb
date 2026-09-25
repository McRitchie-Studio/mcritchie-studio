# frozen_string_literal: true

# [unit] The decision rules behind `bin/task wait-window` (bin/lib/wait_window.rb):
# the parse, the deadline, and every FIRING condition of the loop — answered,
# lapsed, unreadable, gone — against an injected clock, so no test here can pass
# on a watcher that waits forever.
#
#   ruby -Itest test/lib/wait_window_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../../bin/lib/wait_window"

class WaitWindowTest < Minitest::Test
  NOW = Time.utc(2026, 9, 24, 20, 0, 0)

  # A fake clock the sleeper advances, so the loop's own sleeps move time.
  class FakeClock
    attr_reader :now, :sleeps

    def initialize(now)
      @now = now
      @sleeps = []
    end

    def clock = -> { @now }
    def sleeper = ->(seconds) { @sleeps << seconds; @now += seconds }
  end

  def window(kind, ends_at)
    { "kind" => kind, "ends_at" => ends_at.utc.iso8601, "lapsed" => false }
  end

  def task(windows: [], approval: "waiting", blocked_at: nil, block_kind: nil, stage: "building")
    { "slug" => "demo", "stage" => stage, "blocked_at" => blocked_at, "block_kind" => block_kind,
      "metadata" => { "devops" => { "approval_status" => approval } }, "windows" => windows }
  end

  def wait(reads, clock, interval: 15, grace: 60, json: false)
    queue = reads.dup
    reader = -> { queue.size > 1 ? queue.shift : queue.first }
    out = StringIO.new
    err = StringIO.new
    code = WaitWindow.run(slug: "demo", reader: reader, sleeper: clock.sleeper, clock: clock.clock,
                          interval: interval, grace: grace, out: out, err: err, json: json)
    [code, out.string, err.string]
  end

  # --- parse -------------------------------------------------------------------

  def test_parse_defaults_and_flags
    opts = WaitWindow.parse_args(["demo"])
    assert_equal "demo", opts.slug
    assert_equal WaitWindow::DEFAULT_INTERVAL_S, opts.interval
    assert_equal WaitWindow::DEFAULT_GRACE_S, opts.grace
    refute opts.json

    opts = WaitWindow.parse_args(["demo", "--interval", "5", "--grace", "0", "--json"])
    assert_equal 5, opts.interval
    assert_equal 0, opts.grace
    assert opts.json
  end

  def test_parse_refuses_a_missing_slug_an_unknown_flag_a_second_positional_and_a_bad_number
    assert_raises(WaitWindow::UsageError) { WaitWindow.parse_args([]) }
    assert_raises(WaitWindow::UsageError) { WaitWindow.parse_args(["demo", "--forever"]) }
    assert_raises(WaitWindow::UsageError) { WaitWindow.parse_args(["demo", "other"]) }
    assert_raises(WaitWindow::UsageError) { WaitWindow.parse_args(["demo", "--interval", "0"]) }
    assert_raises(WaitWindow::UsageError) { WaitWindow.parse_args(["demo", "--grace", "soon"]) }
    assert_raises(WaitWindow::UsageError) { WaitWindow.parse_args(["--help"]) }
  end

  # --- deadline ----------------------------------------------------------------

  def test_deadline_is_the_latest_end_plus_the_grace_and_nil_when_nothing_is_open
    windows = [window("approval", NOW + 100), window("escalation", NOW + 400)]
    assert_equal NOW + 460, WaitWindow.deadline(windows, grace: 60)
    assert_nil WaitWindow.deadline([], grace: 60)
    assert_empty WaitWindow.windows(task(windows: [{ "kind" => "approval", "ends_at" => "nope" }]))
  end

  # --- firing conditions -------------------------------------------------------

  def test_nothing_open_at_start_is_answered_at_once
    clock = FakeClock.new(NOW)
    code, out, = wait([task(windows: [], approval: "approved")], clock)
    assert_equal WaitWindow::EXIT_ANSWERED, code
    assert_match(/answered — no window was open/, out)
    assert_empty clock.sleeps, "no sleep when there is nothing to wait for"
  end

  def test_a_window_that_closes_is_answered_and_the_verdict_names_what_was_open
    clock = FakeClock.new(NOW)
    reads = [task(windows: [window("escalation", NOW + 600)], blocked_at: NOW.iso8601, block_kind: "dependency"),
             task(windows: [window("escalation", NOW + 600)], blocked_at: NOW.iso8601, block_kind: "dependency"),
             task(windows: [], approval: "none")]
    code, out, = wait(reads, clock, json: true)
    assert_equal WaitWindow::EXIT_ANSWERED, code
    assert_match(/escalation 10:00 left/, out)
    assert_match(/answered — escalation window closed · approval_status none · not blocked/, out)
    verdict = JSON.parse(out.lines.last)
    assert_equal "answered", verdict["verdict"]
    assert_equal ["escalation"], verdict["windows_at_start"].map { |w| w["kind"] }
    assert_equal false, verdict["blocked"]
    assert_equal [15, 15], clock.sleeps
  end

  def test_a_window_nobody_answers_lapses_at_its_end_plus_the_grace
    clock = FakeClock.new(NOW)
    code, out, = wait([task(windows: [window("approval", NOW + 100)])], clock, interval: 30, grace: 20, json: true)
    assert_equal WaitWindow::EXIT_LAPSED, code
    assert_match(/lapsed — approval lapsed \(ends 2026-09-24T20:01:40Z\); 20s grace passed/, out)
    assert_equal NOW + 120, clock.now, "the loop stops exactly at end + grace, never later"
    assert_equal [30, 30, 30, 30], clock.sleeps, "the last sleep is trimmed to the deadline"
    assert_equal "lapsed", JSON.parse(out.lines.last)["verdict"]
  end

  def test_the_last_sleep_never_overshoots_the_deadline
    clock = FakeClock.new(NOW)
    wait([task(windows: [window("approval", NOW + 50)])], clock, interval: 40, grace: 0)
    assert_equal [40, 10], clock.sleeps
  end

  def test_three_consecutive_read_failures_exit_1
    clock = FakeClock.new(NOW)
    code, _out, err = wait([nil], clock, interval: 5)
    assert_equal WaitWindow::EXIT_READ_FAILURE, code
    assert_equal 3, err.lines.grep(/board read failed/).size
    assert_equal [5, 5], clock.sleeps, "sleeps between failures, none after the verdict"
  end

  def test_a_good_read_resets_the_failure_count
    clock = FakeClock.new(NOW)
    reads = [nil, nil, task(windows: [window("approval", NOW + 30)]), nil, nil, task(windows: [])]
    code, = wait(reads, clock, interval: 5, grace: 0)
    assert_equal WaitWindow::EXIT_ANSWERED, code
  end

  def test_a_task_that_is_gone_exits_1_at_once
    clock = FakeClock.new(NOW)
    code, out, err = wait([:not_found], clock, json: true)
    assert_equal WaitWindow::EXIT_READ_FAILURE, code
    assert_match(/task not found/, err)
    assert_equal "read_failure", JSON.parse(out.lines.last)["verdict"]
    assert_empty clock.sleeps
  end

  def test_facts_read_the_block_only_while_it_is_live
    live = task(blocked_at: NOW.iso8601, block_kind: "dependency", stage: "building")
    stale = task(blocked_at: NOW.iso8601, block_kind: "dependency", stage: "submitted")
    assert_equal true, WaitWindow.facts(live)["blocked"]
    assert_equal "dependency", WaitWindow.facts(live)["block_kind"]
    assert_equal false, WaitWindow.facts(stale)["blocked"]
  end
end
