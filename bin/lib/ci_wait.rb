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
  #
  # `read_s` is the MEASURED duration of the final probe — the one `settle` timed,
  # not one deduced from the nap cap. It exists because the first cut of `overrun`
  # inferred it and was wrong (see the note there); a module whose whole subject is
  # "report the read, never the repo" has no business inferring how long the read took.
  Result = Struct.new(:state, :outcome, :polls, :waited_s, :budget_s, :read_s, keyword_init: true) do
    # The wait SETTLED on a real verdict (`:settled`) or gave up (`:timeout` /
    # `:absent` / `:unread`). None of these is a pass or a fail — dor-check decides.
    def timed_out? = outcome == :timeout
    # GitHub answered and reported no checks.
    def absent? = outcome == :absent
    # We never heard from GitHub. NOT the same fact, and never reported as one.
    def unread? = outcome == :unread
    def settled? = outcome == :settled

    # The read was REFUSED — ci_status.rb's own :unreadable, a 401/403 on the TOKEN.
    # It SETTLES, because waiting cannot mend a credential, but it is not a verdict
    # and its remedy is the token. A predicate here rather than a state-name match at
    # the call site, so the one caller that needs the distinction gets it from the
    # module that owns the states.
    def token_refused? = state.to_s.to_sym == :unreadable
  end

  # The loop. Impure only through injected collaborators, so the harness drives it
  # deterministically with no sleeping and no clock.
  #
  #   probe    → a CiStatus state symbol (called at least once, always)
  #   reporter → optional, called before each sleep so a long wait is never silent
  #
  # A silent block is indistinguishable from a hang, and this codebase has already
  # paid for that lesson once (the cert orphan that read as a slow suite).
  # THE DEFAULT CLOCK COUNTS HOST SUSPEND, AND THAT IS KEPT DELIBERATELY. On macOS
  # Process::CLOCK_MONOTONIC keeps counting while the lid is closed — measured on the
  # ship machine during the review of this task at CLOCK_MONOTONIC 2_375_243s against
  # CLOCK_UPTIME_RAW 1_682_913s, i.e. 692_330s (eight days) of suspend that the
  # monotonic clock counted. It is kept because BOTH budgets ask a question about
  # elapsed REAL time at GitHub — "has a run had long enough to appear / to finish?"
  # — and GitHub keeps working while this laptop sleeps, so a wait resumed after a
  # suspend should give up, not politely start its budget over. Switching is also
  # worse than it looks: CLOCK_UPTIME_RAW is Darwin-only, and the two constants INVERT
  # across platforms (on Linux CLOCK_MONOTONIC already excludes suspend and
  # CLOCK_BOOTTIME is the suspend-inclusive one), so pinning it would make the waiter
  # behave one way on the ship machine and another in CI, silently. The suspend was
  # never the defect anyway — ATTRIBUTING that wall-clock to a `gh` read was. The
  # probe is timed below, so the elapsed figure is honest under either clock.
  def self.settle(probe:, timeout_s: DEFAULT_TIMEOUT_S, appearance_s: DEFAULT_APPEARANCE_S,
                  interval_s: DEFAULT_INTERVAL_S, sleeper: ->(s) { sleep(s) },
                  clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, reporter: nil)
    interval = [interval_s, MIN_INTERVAL_S].max
    started = clock.call
    polls = 0

    loop do
      # TIME THE READ. `overrun` used to deduce this from the nap cap and got it
      # wrong; the only trustworthy figure is the one taken around the call.
      read_started = clock.call
      state = probe.call.to_s.to_sym
      now = clock.call
      polls += 1
      read_s = now - read_started
      waited = now - started

      emerging_expired = waited >= appearance_s
      if action_for(state, emerging_expired: emerging_expired) == :settle
        # An expired EMERGING state reports by WHAT WAS READ: a failed read cannot
        # conclude anything about the repo, so it never borrows :absent's sentence.
        outcome, budget = if EMERGING.include?(state) && emerging_expired
                            [UNREAD.include?(state) ? :unread : :absent, appearance_s]
                          else
                            [:settled, nil]
                          end
        return Result.new(state: state, outcome: outcome, polls: polls, waited_s: waited,
                          budget_s: budget, read_s: read_s)
      end

      remaining = timeout_s - waited
      if remaining <= 0
        return Result.new(state: state, outcome: :timeout, polls: polls, waited_s: waited,
                          budget_s: timeout_s, read_s: read_s)
      end

      # Never sleep past either budget — an emerging state must be re-judged the
      # moment its shorter window closes, not one full interval later.
      nap = [interval, remaining, (emerging_expired ? remaining : appearance_s - waited)].reject(&:negative?).min
      # REPORT THE BUDGET ACTUALLY IN FORCE. An EMERGING state that reaches here is
      # by definition not yet expired, and it is judged against the APPEARANCE budget
      # — so handing the reporter `timeout_s - waited` printed "900s left" beside a
      # state that had 120s. Same one-line habit as the rest of this file: the number
      # a reader sees must be the number the code is about to act on.
      reporter&.call(state, polls, EMERGING.include?(state) ? appearance_s - waited : remaining)
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
  # BETWEEN polls and never during one, so the elapsed CAN exceed one — a fact worth
  # printing rather than hiding, since a reader who cannot reconcile the two numbers
  # stops believing everything else on the line.
  #
  # WHERE THE EXCESS SAT IS MEASURED, NOT INFERRED — and the first cut of this note
  # inferred it and was FALSE. It attributed the whole excess to the final read, on
  # the reasoning that `nap` is capped at the remaining budget so a sleep can never
  # carry `waited` past one. The cap is on the nap the loop COMPUTES. The REALIZED
  # sleep is only LOWER-bounded (Kernel#sleep's contract), so any wall-clock the
  # process loses inside `sleeper.call(nap)` lands in `waited` with ZERO read time.
  # Deterministic counterexample, now pinned in ci_wait_test.rb: two instant polls and
  # one 20s nap realized as 600s renders a 480s overrun in which no read was slow.
  # And it is live on this machine — the default clock counts host suspend (see
  # `settle`), which makes a lid-close mid-nap the likeliest real producer of the
  # 2277s figure above. So the old note would have "explained" the very incident this
  # task was filed over with a `gh` call that never ran slow: a written claim
  # vouching for more than the mechanism delivers, inside the module written to end
  # exactly that, one layer down.
  #
  # Hence `settle` TIMES the probe and carries `read_s`, and this prints that measured
  # number. Whatever is left over is named for what it is — wall-clock the loop does
  # not bound, and therefore does not get to attribute.
  #
  # It fires only when a READER would see two numbers that disagree. Sub-second
  # slippage is ordinary poll granularity, and explaining a discrepancy nobody can
  # see would be its own small over-claim — the very habit this task exists to break.
  # (Measured while fixing this: a 6.2s wait on a 6s budget printed a dire note about
  # a read that had not returned, when four reads had returned promptly.)
  def self.overrun(result)
    budget = result.budget_s
    return "" unless budget && result.waited_s.round > budget

    excess = result.waited_s - budget
    read = result.read_s.to_f
    unbounded = excess - read
    note = " (past the #{budget}s budget by #{excess.round}s; the final read MEASURED #{read.round}s"
    if unbounded.round.positive?
      note += ", so the remaining #{unbounded.round}s sat in a nap that overslept or a host " \
              "suspend — the loop bounds the nap it COMPUTES, never wall-clock"
    end
    "#{note})"
  end
end
