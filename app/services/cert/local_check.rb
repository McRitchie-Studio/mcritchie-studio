module Cert
  # What the board says about a LOCAL certification that is happening right now.
  #
  # The operator's question is "this task has been in `building` a while — is
  # anything actually happening?" Until now the board could not answer it: the
  # PR CI meter only appears once `bin/ship` has opened a PR, and everything
  # BEFORE that — the cert that runs first, and is the slow part — was invisible.
  # Observed live: a `bin/fast-check` ran past seven minutes against an advertised
  # ~1 minute while its card showed nothing at all.
  #
  # The signal already existed; nothing read it. `bin/fast-check` opens a
  # `g1_cert` GateRun before its first lane and closes it at the verdict, so an
  # IN-FLIGHT g1_cert attempt IS "a local check is running". This wraps that row
  # in the three questions the card asks: which lane, how long, and — the one that
  # matters — is it still alive.
  #
  # WHY LIVENESS IS THE POINT, not decoration. A start/stop marker alone would
  # spin forever whenever the runner is killed, and killed runners are ROUTINE
  # here: the operating model itself warns that a cold `bin/ship` exceeds what
  # some agent harnesses allow one foreground command and tells agents to expect
  # to re-run it. A spinner that cannot die would report "working" for precisely
  # the abandoned tasks this feature exists to expose — worse than showing
  # nothing, because it converts an unknown into a confident wrong answer. So the
  # certs heartbeat their running lane, and a beat older than STALE_AFTER renders
  # as STALLED instead.
  #
  # THREE STATES, and the split between the first two is the correctness of the
  # whole widget:
  #
  #   · NO-SIGNAL — an attempt is open and has NEVER reported a running lane. We
  #     know a cert started; we know nothing about whether it still lives.
  #   · RUNNING   — a lane reported liveness recently.
  #   · STALLED   — a lane reported liveness and then went quiet.
  #
  # ABSENCE OF A SIGNAL IS NOT EVIDENCE OF A STALL. This distinction is not
  # hypothetical tidiness: the `bin/fast-check` shipped on `accepted` opens a
  # g1_cert attempt and emits ONLY terminal pass/fail sops — no running row at
  # all. Collapsing no-signal into stalled therefore painted STALLED over every
  # healthy multi-minute cert on every desk that had not yet rebased onto this
  # branch — the whole population of live worktrees, on merge day, which is
  # exactly the audience and the moment the feature exists for. Only a run that
  # actually reported liveness and then stopped may be called dead; a run that
  # never reported at all is simply not something this widget can speak about,
  # and Cert::LocalCheckReader drops it rather than guess (see #reportable?).
  class LocalCheck
    # How long without a beat before a check is presumed dead. Comfortably longer
    # than the certs' ~40s heartbeat (two missed beats plus slack), so a busy
    # machine cannot flicker a healthy run into the stalled state.
    STALE_AFTER = 100.seconds

    # Lane labels the certs emit are terse and internal ("mapped-tests"). The card
    # has one short line, so name them the way an operator would.
    LANE_LABELS = {
      "test-prepare"    => "Preparing test DB",
      "mapped-tests"    => "Running mapped tests",
      "spine"           => "Running core spine",
      "rubocop-changed" => "Linting changed files",
      "full-suite"      => "Running full suite",
      "rubocop"         => "Linting"
    }.freeze

    # Used when a lane reports liveness without naming itself — a real emit with a
    # blank `sop`. NOT used for the no-signal case, which renders nothing at all.
    FALLBACK_LABEL = "Running local checks"

    def self.from_gate_run(run, now: Time.current)
      return nil if run.blank?
      return nil unless run.finished_at.nil?

      new(run, now: now)
    end

    def initialize(run, now: Time.current)
      @run = run
      @now = now
    end

    def started_at = @run.started_at

    # The lane currently in flight — the last sop entry still marked `running`.
    # `append_sop!` supersedes a running entry when that lane settles, so any
    # running row that survives is genuinely the one in progress.
    def running_sop
      return @running_sop if defined?(@running_sop)

      @running_sop = @run.sops.reverse.find { |sop| sop["result"].to_s == GateRun::RUNNING_RESULT }
    end

    # Did this runner ever prove it was alive? Everything below turns on it.
    def signal? = running_sop.present?

    # Whether the card may say ANYTHING about this attempt. No signal means no
    # claim — not "running", and emphatically not "stalled".
    def reportable? = signal?

    def lane = running_sop&.dig("sop").presence

    def label
      LANE_LABELS.fetch(lane) { lane.presence || FALLBACK_LABEL }
    end

    # The command behind the lane — the card's tooltip, so the operator can see
    # (and copy) exactly what is running without opening the session.
    def command = running_sop&.dig("cmd").presence

    # Last proof of life: the running lane's own timestamp, which the heartbeat
    # refreshes in place. NIL when the runner never reported a lane — there is no
    # proof of life to date, and dating it from the attempt's start would invent
    # one. A lane that reported but carried an unparseable stamp still counts as a
    # signal, so that one falls back to the attempt start rather than vanishing.
    def heartbeat_at
      return nil unless signal?

      @heartbeat_at ||= parse_time(running_sop["at"]) || started_at
    end

    def seconds_since_heartbeat
      beat = heartbeat_at
      return nil if beat.nil?

      (@now - beat).to_i
    end

    # The moment this check will start reading as stalled — handed to the card so
    # an ALREADY-OPEN board can flip itself at the right second instead of waiting
    # for a write that a killed runner will never make.
    def stale_at
      beat = heartbeat_at
      beat && beat + STALE_AFTER
    end

    def elapsed_seconds = [(@now - started_at).to_i, 0].max

    # Where the clock FREEZES when the runner dies: time from the attempt's start
    # to its last proof of life. A stalled clock that kept climbing would keep
    # claiming progress that is not happening.
    def elapsed_at_last_beat
      beat = heartbeat_at
      return 0 if beat.nil?

      [(beat - started_at).to_i, 0].max
    end

    # STALLED is a claim about the RUNNER, not the tests: the process stopped
    # reporting. The card must not say "failed" — nobody knows the verdict, which
    # is exactly the operator's problem.
    def stalled?
      since = seconds_since_heartbeat
      !since.nil? && since > STALE_AFTER
    end

    def running? = signal? && !stalled?

    def state
      return :no_signal unless signal?

      stalled? ? :stalled : :running
    end

    def attempt = @run.attempt

    private

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
