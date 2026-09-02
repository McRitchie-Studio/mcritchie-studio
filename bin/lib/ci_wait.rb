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
# when the READ ITSELF fails and a later poll may still get through. A wait that
# treats either as settled exits within a second of the push, every time, and the
# feature silently does nothing — which is indistinguishable from working, because
# the handoff still succeeds. So they wait too, on a SHORTER budget: `:none` that
# persists means no CI is ever coming (a repo with no workflow), and that must not
# burn the full timeout.
#
# (`:unverified` is NOT "GitHub still computing mergeability", which is how this
# paragraph read until the review of task ship-waiter-misreports-ci: ci_status.rb's
# view_verdict resolves an UNKNOWN mergeStateStatus to NO verdict and never to
# `:unverified`. Reading a failed read as a benign transient of GitHub's own making is
# the exact misconception this task was filed to fix — it cannot stand six lines above
# the note that fixes it. The same sentence in docs/agents/modules/devops-task-board.md
# was corrected on this branch; this copy was missed.)
#
# WAITING ALIKE IS NOT REPORTING ALIKE (task ship-waiter-misreports-ci, 2026-09-01).
# Those two transient states share a BUDGET and nothing else. `:none` is GitHub
# answering; `:unverified` is the read failing. They expire into different outcomes
# (`:absent` vs `:unread`) and different sentences, because the remedy differs: an
# absent run means judge the repo as it stands, an unread one means fix the read and
# ask again. This module is entitled to relay what GitHub said and NOTHING MORE — it
# never asserts what a repo holds on the strength of a query that failed.
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
  #
  # SPLIT BY WHAT THE READ MEANS, not merely by "we have no verdict yet". Both wait
  # on the same short budget — that part was right — but they EXPIRE INTO DIFFERENT
  # REPORTS, and that distinction is the whole of task ship-waiter-misreports-ci:
  #
  #   :none       — GitHub ANSWERED and reported no checks. "No CI run appeared" is a
  #                 fair relay of something GitHub actually said.
  #   :unverified — the READ FAILED. This is CiStatus's own name for a gh/network
  #                 error: GitHub said NOTHING, so any claim about what the repo holds
  #                 is invented. Measured on PR #1143 — `gh pr checks` 12/12 GREEN and
  #                 dor-check "GitHub CI green (12 checks)" at the same moment this
  #                 module printed "treating this PR as having none".
  #
  # ci_status.rb already paid for this exact collapse once, between :unreadable and
  # :unverified ("A BLIND GATE MUST SAY WHY IT IS BLIND"). This module repeated it a
  # layer up — on the one line a builder reads while deciding whether to trust a ship.
  # The cost is not the wrong word: "treating this PR as having none" invites shipping
  # past a green CI, and teaches a reader that this output is unreliable, which is how
  # a genuinely RED CI later gets waved through as "probably the waiter again".
  AWAITING = %i[none].freeze
  UNREAD = %i[unverified].freeze
  EMERGING = (AWAITING + UNREAD).freeze

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

  # `budget_s` is the budget THIS outcome was judged against (nil when none applied),
  # carried so the summary can reconcile the elapsed figure against it instead of
  # printing a number that looks impossible next to the configured timeout.
  Result = Struct.new(:state, :outcome, :polls, :waited_s, :budget_s, keyword_init: true) do
    # The wait SETTLED on a real verdict (`:settled`) or gave up (`:timeout` /
    # `:absent` / `:unread`). None of these is a pass or a fail — dor-check decides.
    def timed_out? = outcome == :timeout
    # GitHub answered and reported no checks.
    def absent? = outcome == :absent
    # We never heard from GitHub. NOT the same fact, and never reported as one.
    def unread? = outcome == :unread
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
        # An expired EMERGING state reports by WHAT WAS READ: a failed read cannot
        # conclude anything about the repo, so it never borrows :absent's sentence.
        outcome, budget = if EMERGING.include?(state) && emerging_expired
                            [UNREAD.include?(state) ? :unread : :absent, appearance_s]
                          else
                            [:settled, nil]
                          end
        return Result.new(state: state, outcome: outcome, polls: polls, waited_s: waited, budget_s: budget)
      end

      remaining = timeout_s - waited
      if remaining <= 0
        return Result.new(state: state, outcome: :timeout, polls: polls, waited_s: waited, budget_s: timeout_s)
      end

      # Never sleep past either budget — an emerging state must be re-judged the
      # moment its shorter window closes, not one full interval later.
      nap = [interval, remaining, (emerging_expired ? remaining : appearance_s - waited)].reject(&:negative?).min
      reporter&.call(state, polls, remaining)
      sleeper.call(nap)
    end
  end

  # The line bin/ship prints for a finished wait. Kept here so the wording lives
  # beside the semantics it describes.
  #
  # THE RULE: REPORT THE READ, NEVER THE REPO. This module observes exactly one thing
  # — what a CI query returned — and every sentence below stays inside that. It may
  # relay what GitHub said. It may not assert what GitHub HOLDS when GitHub never
  # answered, because "no CI run appeared" is a claim about GitHub and a failed read
  # is not evidence for it. Same discipline as cert_process.rb's diagnosis: say what
  # was seen, name what it cannot distinguish, and put the numbers in the same breath.
  def self.summary(result)
    elapsed = "#{result.waited_s.round}s#{overrun(result)}"

    case result.outcome
    when :settled
      "CI settled on #{result.state} after #{elapsed} (#{result.polls} poll(s))"
    when :absent
      "no CI run appeared within #{elapsed} — GitHub answered and reported no checks, " \
        "so dor-check judges the PR as it stands"
    when :unread
      "could not read CI within #{elapsed} — the last read returned #{result.state}, which is a " \
        "gh/network fault rather than an answer from GitHub, so whether this PR has CI is UNKNOWN. " \
        "This is NOT a report that the PR has no CI; dor-check re-reads it next and owns the verdict"
    when :timeout
      "CI still #{result.state} after #{elapsed} — giving up the wait"
    end
  end

  # Reconcile the elapsed figure with the budget it was judged against.
  #
  # THE SECOND DEFECT on PR #1143: "no CI run appeared within 2277s" printed under a
  # 900s timeout and a 120s appearance budget. 2277 cannot come from either, so the
  # figure reads as an arithmetic error — and a reader who decides this module cannot
  # count stops believing the next thing it says, including a genuinely red CI.
  #
  # The elapsed is TRUE wall-clock; nothing is miscomputed. The budgets are tested
  # BETWEEN polls and never during one, and naps are already capped so a sleep can
  # never cross a budget — so the ONLY way elapsed can exceed it is a single read that
  # did not return within it. That is a fact worth printing, not hiding: it points at
  # a hung `gh` call, which is also the likeliest producer of the :unverified above.
  # WHY THE ATTRIBUTION IS SOUND, and not another guess: `nap` is already capped at
  # the remaining budget on every branch, so a sleep can never carry `waited` past
  # one. Whatever excess exists therefore accrued inside the FINAL read — the only
  # unbounded step in the loop. That is a measurement, not an inference about GitHub.
  #
  # It fires only when a READER would see two numbers that disagree. Sub-second
  # slippage is ordinary poll granularity, and explaining a discrepancy nobody can
  # see would be its own small over-claim — the very habit this task exists to break.
  # (Measured while fixing this: a 6.2s wait on a 6s budget printed a dire note about
  # a read that had not returned, when four reads had returned promptly.)
  def self.overrun(result)
    budget = result.budget_s
    return "" unless budget && result.waited_s.round > budget

    " (past the #{budget}s budget — budgets are tested BETWEEN polls and a nap never " \
      "crosses one, so the final read alone ran ~#{(result.waited_s - budget).round}s long)"
  end
end
