# frozen_string_literal: true

# [unit] The handoff's CI settle wait — bin/lib/ci_wait.rb.
#
# The decision logic is PURE and the loop takes injected collaborators, so every
# case here runs with no clock, no sleeping, and no `gh`. Run directly:
#   ruby -Itest test/lib/ci_wait_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# The integration half — that bin/ship actually CALLS this, and that a red CI
# leaves the task in `building` — lives in test/lib/ship_test.rb. Both halves are
# needed: this file proves the rule, that one proves the rule is on the path.
require "minitest/autorun"
require_relative "../../bin/lib/ci_wait"

class CiWaitTest < Minitest::Test
  # A probe that returns each state in turn, then repeats the last one forever.
  def probe_over(*states)
    queue = states.dup
    -> { queue.size > 1 ? queue.shift : queue.first }
  end

  # Drive the loop with a fake clock that advances by `step` on every reading, so
  # elapsed time is deterministic and nothing sleeps.
  def settle(probe, step: 10, **kwargs)
    now = 0.0
    clock = lambda do
      value = now
      now += step
      value
    end
    CiWait.settle(probe: probe, sleeper: ->(_s) { }, clock: clock, **kwargs)
  end

  # ── the classifier ─────────────────────────────────────────────────────────

  def test_pending_waits_and_a_real_verdict_settles
    assert_equal :wait, CiWait.action_for(:pending)

    # Every state that is not "still running" hands off to dor-check. Red is in
    # this list DELIBERATELY: the wait does not refuse a red CI, dor-check does.
    %i[green red conflicted closed merged ci_less unreadable no_pr].each do |state|
      assert_equal :settle, CiWait.action_for(state), "#{state} must settle, not wait"
    end
  end

  def test_an_unknown_state_settles_rather_than_waiting_forever
    # CiStatus::TOKENS may grow. A state this module has never heard of must
    # degrade to the behaviour that predates this file, never to an unbounded wait.
    assert_equal :settle, CiWait.action_for(:some_state_invented_next_year)
  end

  def test_emerging_states_wait_only_until_the_appearance_budget_expires
    %i[none unverified].each do |state|
      assert_equal :wait, CiWait.action_for(state, emerging_expired: false), "#{state} is transient at first"
      assert_equal :settle, CiWait.action_for(state, emerging_expired: true), "#{state} must give up eventually"
    end
  end

  def test_a_string_state_classifies_the_same_as_a_symbol
    assert_equal :wait, CiWait.action_for("pending")
    assert_equal :settle, CiWait.action_for("green")
  end

  # ── the loop ───────────────────────────────────────────────────────────────

  def test_it_polls_until_a_pending_run_goes_green
    result = settle(probe_over(:pending, :pending, :green), timeout_s: 900, appearance_s: 120)

    assert_equal :green, result.state
    assert_equal :settled, result.outcome
    assert_equal 3, result.polls
  end

  def test_a_red_ci_settles_immediately_and_is_not_reported_as_a_failure_here
    result = settle(probe_over(:red), timeout_s: 900)

    assert_equal :red, result.state
    # `:settled` — the wait's job is done. Whether red BLOCKS is dor-check's call,
    # and asserting a pass/fail verdict here would duplicate that gate.
    assert_equal :settled, result.outcome
    assert_equal 1, result.polls
  end

  def test_a_green_ci_needs_exactly_one_poll
    result = settle(probe_over(:green))

    assert_equal 1, result.polls
    assert_predicate result, :settled?
  end

  def test_a_run_that_never_finishes_times_out_and_reports_the_last_state
    result = settle(probe_over(:pending), step: 100, timeout_s: 250, appearance_s: 120)

    assert_equal :pending, result.state
    assert_predicate result, :timed_out?
    refute_predicate result, :settled?
  end

  def test_a_run_that_never_appears_gives_up_on_the_SHORTER_appearance_budget
    # THE BUG THIS PINS: `gh pr checks` reports :none between the push and GitHub
    # creating the run. Treat :none as settled and the wait exits within a second
    # of every push — the feature silently does nothing while still "succeeding".
    # Treat it as :pending and a repo with NO ci.yml burns the full timeout.
    result = settle(probe_over(:none), step: 30, timeout_s: 900, appearance_s: 60)

    assert_equal :none, result.state
    assert_predicate result, :absent?
    assert_operator result.waited_s, :<, 900, "must not burn the full timeout on a run that is never coming"
  end

  def test_a_run_that_appears_late_is_still_waited_out_in_full
    # :none first (the creation lag), then a real run. The appearance budget must
    # not have cost us the run — once CI EXISTS, the full timeout applies again.
    result = settle(probe_over(:none, :pending, :pending, :green), step: 10, timeout_s: 900, appearance_s: 60)

    assert_equal :green, result.state
    assert_predicate result, :settled?
  end

  # ── configuration ──────────────────────────────────────────────────────────

  def test_the_wait_is_armed_unless_explicitly_switched_off
    assert CiWait.enabled?({})
    assert CiWait.enabled?({ "SHIP_CI_WAIT" => "" })
    assert CiWait.enabled?({ "SHIP_CI_WAIT" => "on" })
    # Only the exact token disarms it — a typo must not silently drop the gate.
    assert CiWait.enabled?({ "SHIP_CI_WAIT" => "offf" })
    refute CiWait.enabled?({ "SHIP_CI_WAIT" => "off" })
    refute CiWait.enabled?({ "SHIP_CI_WAIT" => "OFF" })
  end

  def test_a_bad_knob_is_ignored_rather_than_crashing_the_handoff
    # Same discipline as TestParallelism.worker_count: a malformed env var must
    # never be able to kill a handoff mid-flight.
    %w[banana -5 0 1.5)].each do |bad|
      cfg = CiWait.config({ "SHIP_CI_WAIT_TIMEOUT" => bad })
      assert_equal CiWait::DEFAULT_TIMEOUT_S, cfg[:timeout_s], "#{bad.inspect} must fall back"
    end
  end

  def test_the_poll_interval_is_floored
    # A spin loop burns a gh call per iteration and hits the API rate limit, whose
    # failure mode is :unreadable — the wait would poison the verdict it exists to get.
    assert_equal CiWait::MIN_INTERVAL_S, CiWait.config({ "SHIP_CI_WAIT_INTERVAL" => "1" })[:interval_s]
    assert_equal 45, CiWait.config({ "SHIP_CI_WAIT_INTERVAL" => "45" })[:interval_s]
  end

  def test_config_defaults_when_nothing_is_set
    cfg = CiWait.config({})

    assert_equal CiWait::DEFAULT_TIMEOUT_S, cfg[:timeout_s]
    assert_equal CiWait::DEFAULT_APPEARANCE_S, cfg[:appearance_s]
    assert_equal CiWait::DEFAULT_INTERVAL_S, cfg[:interval_s]
  end

  # ── reporting ──────────────────────────────────────────────────────────────

  def test_a_long_wait_is_never_silent
    # A silent block is indistinguishable from a hang — this codebase has paid for
    # that lesson once already (the cert orphan that read as a slow suite).
    seen = []
    settle(probe_over(:pending, :pending, :green),
           timeout_s: 900, appearance_s: 120,
           reporter: ->(state, polls, left) { seen << [state, polls, left] })

    refute_empty seen, "the wait must report progress between polls"
    assert_equal :pending, seen.first[0]
  end

  def test_each_give_up_path_says_which_one_it_was
    # "CI said no" and "we stopped asking" demand different actions from the
    # operator, so they must never render as the same sentence.
    timed_out = settle(probe_over(:pending), step: 100, timeout_s: 150)
    absent = settle(probe_over(:none), step: 100, timeout_s: 900, appearance_s: 50)
    green = settle(probe_over(:green))

    assert_match(/still pending/, CiWait.summary(timed_out))
    assert_match(/no CI run appeared/, CiWait.summary(absent))
    assert_match(/settled on green/, CiWait.summary(green))
    refute_equal CiWait.summary(timed_out), CiWait.summary(absent)
  end
end
