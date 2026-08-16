# frozen_string_literal: true

# bin/lib/ci_wait.rb — the handoff's CI settle wait.
#
# ONE job, stated narrowly on purpose: stop bin/ship from running the DoR verdict
# while the PR's CI is still RUNNING, when waiting can turn "pending" into a real
# verdict. It changes WHEN bin/dor-check runs. It never changes WHETHER it runs,
# and it never decides anything dor-check decides.
#
# WHY THAT BOUNDARY IS THE WHOLE DESIGN. The obvious version of this feature reads
# the CI state and decides the handoff itself — advance on green, refuse on red.
# That duplicates bin/dor-check's allow-list in a second place, and the two copies
# drift the first time either grows a state. So this module classifies into exactly
# two buckets — KEEP WAITING, or STOP WAITING — and hands the verdict to the gate
# that already owns it. A red CI still stops the handoff, but it stops it because
# dor-check refuses (recording a failed `dor` attempt, naming the failing checks),
# exactly as it does today. Nothing here is a gate.
#
# WHAT IT REPLACES (task gate-submit-on-green-ci, 2026-08-16). The builder used to
# certify the FULL suite locally — measured at ~31 min against CI's ~9 min for the
# identical command — then push and hand off WITHOUT waiting for CI, on the
# reasoning recorded in docs/agents/modules/gates/dor.md (`ci-gate-review-handoff`,
# 2026-07-09): "the CI wait belongs to the review handoff, not the builder's
# wall-clock". That reasoning was sound while the builder was ALSO paying for a
# local full suite. Drop the local suite and the arithmetic inverts: the builder
# gets ~20 min back and the wait costs ~10, so `submitted` can carry a GREEN CI
# instead of a provisional one — and a red CI is caught by the session that still
# has the worktree warm, rather than by a bounce into a cold one.
#
# THREE STATES ARE TRANSIENT, NOT TWO — this is the bug the first cut would have had.
# `:pending` is the obvious one. But `gh pr checks` reports `:none` in the window
# between `git push` and GitHub actually CREATING the workflow run, and `:unverified`
# while GitHub is still computing mergeability. A wait that treats either as settled
# exits within a second of the push, every time, and the feature silently does
# nothing — which is indistinguishable from working, because the handoff still
# succeeds. So they wait too, on a SHORTER budget: `:none` that persists means no CI
# is ever coming (a repo with no workflow), and that must not burn the full timeout.
#
# EVERY UNKNOWN STATE SETTLES, DELIBERATELY. CiStatus::TOKENS may grow. A state this
# module has never heard of resolves to STOP WAITING, so the failure mode of an
# un-taught state is "behaves exactly as it did before this file existed" — never an
# unbounded wait on a symbol nobody here recognises. Fail toward the status quo.

require_relative "ci_status"

module CiWait
  # The full budget for a run that is genuinely executing.
  DEFAULT_TIMEOUT_S = 900

  # The budget for CI merely APPEARING. A run that has not been created within this
  # window is treated as never coming, and dor-check judges the repo it actually has.
  DEFAULT_APPEARANCE_S = 120

  DEFAULT_INTERVAL_S = 20

  # A spin loop is worse than no wait: it burns a `gh` call per iteration and hits
  # the API rate limit, whose failure mode is :unreadable — the wait would poison
  # the very verdict it exists to obtain.
  MIN_INTERVAL_S = 2

  # Still running. Worth the full timeout.
  RUNNING = %i[pending].freeze

  # Not running YET — or never will. Worth only the appearance budget.
  EMERGING = %i[none unverified].freeze

  # PURE. A CiStatus state → :wait or :settle, given how long we have been waiting.
  # `emerging_expired` is the caller's answer to "has the appearance budget run
  # out", kept out of here so this stays a pure function of the state.
  def self.action_for(state, emerging_expired: false)
    sym = state.to_s.to_sym
    return :wait if RUNNING.include?(sym)
    return emerging_expired ? :settle : :wait if EMERGING.include?(sym)

    :settle
  end

  # PURE. Whether the wait is armed at all. `off` is the harness's switch and the
  # operator's escape hatch; anything else (including unset) arms it, so the
  # feature cannot be disabled by a typo in the value.
  def self.enabled?(env = ENV)
    env["SHIP_CI_WAIT"].to_s.strip.downcase != "off"
  end

  # PURE. Read a positive-integer knob, falling back on anything unparseable.
  # A non-numeric value is IGNORED, never crashed on — a bad env var must not be
  # able to kill a handoff (same discipline as TestParallelism.worker_count).
  def self.duration_from(env, key, fallback)
    raw = env[key].to_s.strip
    return fallback unless raw.match?(/\A\d+\z/)

    value = Integer(raw)
    value.positive? ? value : fallback
  end

  def self.config(env = ENV)
    {
      timeout_s: duration_from(env, "SHIP_CI_WAIT_TIMEOUT", DEFAULT_TIMEOUT_S),
      appearance_s: duration_from(env, "SHIP_CI_WAIT_APPEARANCE", DEFAULT_APPEARANCE_S),
      interval_s: [duration_from(env, "SHIP_CI_WAIT_INTERVAL", DEFAULT_INTERVAL_S), MIN_INTERVAL_S].max
    }
  end

  Result = Struct.new(:state, :outcome, :polls, :waited_s, keyword_init: true) do
    # The wait SETTLED on a real verdict (`:settled`) or gave up (`:timeout` /
    # `:absent`). None of these is a pass or a fail — dor-check decides that.
    def timed_out? = outcome == :timeout
    def absent? = outcome == :absent
    def settled? = outcome == :settled
  end

  # The loop. Impure only through injected collaborators, so the harness drives it
  # deterministically with no sleeping and no clock.
  #
  #   probe    → a CiStatus state symbol (called at least once, always)
  #   reporter → optional, called before each sleep so a long wait is never silent
  #
  # A silent block is indistinguishable from a hang, and this codebase has already
  # paid for that lesson once (the cert orphan that read as a slow suite).
  def self.settle(probe:, timeout_s: DEFAULT_TIMEOUT_S, appearance_s: DEFAULT_APPEARANCE_S,
                  interval_s: DEFAULT_INTERVAL_S, sleeper: ->(s) { sleep(s) },
                  clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, reporter: nil)
    interval = [interval_s, MIN_INTERVAL_S].max
    started = clock.call
    polls = 0

    loop do
      state = probe.call.to_s.to_sym
      polls += 1
      waited = clock.call - started

      emerging_expired = waited >= appearance_s
      if action_for(state, emerging_expired: emerging_expired) == :settle
        outcome = if EMERGING.include?(state) && emerging_expired then :absent
                  else :settled
                  end
        return Result.new(state: state, outcome: outcome, polls: polls, waited_s: waited)
      end

      remaining = timeout_s - waited
      return Result.new(state: state, outcome: :timeout, polls: polls, waited_s: waited) if remaining <= 0

      # Never sleep past either budget — an emerging state must be re-judged the
      # moment its shorter window closes, not one full interval later.
      nap = [interval, remaining, (emerging_expired ? remaining : appearance_s - waited)].reject(&:negative?).min
      reporter&.call(state, polls, remaining)
      sleeper.call(nap)
    end
  end

  # The line bin/ship prints for a finished wait. Kept here so the wording lives
  # beside the semantics it describes.
  def self.summary(result)
    case result.outcome
    when :settled then "CI settled on #{result.state} after #{result.waited_s.round}s (#{result.polls} poll(s))"
    when :absent then "no CI run appeared within #{result.waited_s.round}s — treating this PR as having none"
    when :timeout then "CI still #{result.state} after #{result.waited_s.round}s — giving up the wait"
    end
  end
end
