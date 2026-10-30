# frozen_string_literal: true

# bin/lib/gem_served_wait.rb: the wait between `gem push` and the first consumer
# lock push. Standalone:
#   ruby -Itest test/lib/gem_served_wait_test.rb
#
# THE INCIDENT, rel-20261029-00560a. studio-engine 0.119.0 was published at
# 19:15:48Z; the conductor's single fresh read passed, the lock bumps were pushed,
# and alex-build's `static` job ran `bundle install` 62 seconds later against a
# runner edge that still answered "can no longer be found in that source". These
# cases drive the loop on a fake clock, so no case touches the network or sleeps.
require "minitest/autorun"
require_relative "../../bin/lib/gem_served_wait"

class GemServedWaitTest < Minitest::Test
  # A fake wall clock: each probe costs `per_poll` seconds, each sleep `interval`.
  class Clock
    attr_reader :now, :sleeps

    def initialize = (@now = 0.0; @sleeps = [])
    def read = @now
    def advance(seconds) = @now += seconds
    def sleep(seconds) = (@sleeps << seconds; @now += seconds)
  end

  def run_wait(answers, timeout: 300, interval: 5, settle: 60, per_poll: 0)
    clock = Clock.new
    queue = answers.dup
    calls = 0
    probe = lambda do
      calls += 1
      clock.advance(per_poll)
      queue.empty? ? answers.last : queue.shift
    end
    result = GemServedWait.await(probe: probe, timeout: timeout, interval: interval, settle: settle,
                                 clock: -> { clock.read }, sleeper: ->(s) { clock.sleep(s) })
    [result, calls, clock]
  end

  # ── [unit] listed immediately ─────────────────────────────────────────────

  def test_listed_immediately_with_no_settle_returns_on_the_first_poll
    result, calls, clock = run_wait([true], settle: 0)

    assert_predicate result, :served?
    assert_equal 1, calls
    assert_empty clock.sleeps, "a served answer with no hold must not sleep at all"
  end

  # Served on the first read is NOT enough: it must keep answering for the window.
  def test_listed_immediately_still_holds_for_the_settle_window
    result, calls, = run_wait([true], interval: 5, settle: 60)

    assert_predicate result, :served?
    assert_equal 13, calls, "first served read at t=0, then every 5s until t=60"
    assert_operator result.elapsed, :>=, 60
  end

  # ── [unit] listed after N polls ───────────────────────────────────────────

  def test_listed_after_n_polls_returns_served_on_that_poll
    result, calls, = run_wait([false, false, false, true], settle: 0)

    assert_predicate result, :served?
    assert_equal 4, calls, "three misses, then the read that lists it"
    assert_equal 4, result.polls
  end

  # A miss INSIDE the window starts the hold over: one fresh edge is not proof.
  def test_a_miss_inside_the_settle_window_resets_it
    # served t=0,5 · miss t=10 · served from t=15 on → done at t=15+20=35
    result, calls, = run_wait([true, true, false, true], interval: 5, settle: 20)

    assert_predicate result, :served?
    assert_equal 8, calls, "polls at t=0,5,10 then t=15..35: the hold restarted at the miss"
    assert_in_delta 35, result.elapsed
  end

  # ── [unit] never listed → timeout ─────────────────────────────────────────

  def test_never_listed_times_out
    result, calls, = run_wait([false], timeout: 30, interval: 5, settle: 0)

    refute_predicate result, :served?
    assert_equal :timeout, result.outcome
    assert_equal 7, calls, "t=0..30 every 5s, ending on the read that reaches the bound"
  end

  # A hold that cannot finish inside the budget is a timeout, never a served.
  def test_a_hold_that_outlives_the_budget_times_out
    result, = run_wait([false, false, true], timeout: 30, interval: 5, settle: 60)

    assert_equal :timeout, result.outcome
  end

  # Probe time counts: a hung read must eat the budget, or the deadline never fires.
  def test_the_deadline_counts_probe_time
    result, calls, = run_wait([false], timeout: 100, interval: 0, settle: 0, per_poll: 40)

    assert_equal :timeout, result.outcome
    assert_equal 3, calls, "40, 80, 120: the third read crosses 100s of wall time"
  end

  # ── [unit] the compact-index parsers, against the real payload shapes ──────

  def test_info_matches_a_whole_version_never_a_prefix
    body = "0.47.2 aws-sdk-s3:~> 1.218|checksum:abc\n0.48.0 aws-sdk-s3:~> 1.218|checksum:def\n"

    assert GemServedWait.info_lists?(body, "0.48.0")
    refute GemServedWait.info_lists?(body, "0.49.0")
    refute GemServedWait.info_lists?(body, "0.4")
  end

  # Verified live against https://index.rubygems.org/versions on 2026-10-29: a gem
  # appears on one appended line per publish, "studio-engine 0.119.0 5ecbb13c...".
  def test_versions_reads_every_appended_line_for_the_gem
    tail = "rantly 3.0.0 aaa\nstudio-engine 0.117.0 771c\nstudio-engine-x 0.119.0 zzz\nstudio-engine 0.118.0 dec9\n"

    refute GemServedWait.versions_lists?(tail, "studio-engine", "0.119.0"),
           "a sibling gem whose name starts the same must not count"
    assert GemServedWait.versions_lists?(tail + "studio-engine 0.119.0 5ecb\n", "studio-engine", "0.119.0")
    assert GemServedWait.versions_lists?("studio-engine 0.118.0,0.119.0 md5\n", "studio-engine", "0.119.0")
    refute GemServedWait.versions_lists?("studio-engine 0.119.0 a\nstudio-engine -0.119.0 b\n",
                                         "studio-engine", "0.119.0"), "a later yank line takes it back"
    refute GemServedWait.versions_lists?("", "studio-engine", "0.119.0")
  end
end
