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
      @running_sop ||= @run.sops.reverse.find { |sop| sop["result"].to_s == GateRun::RUNNING_RESULT }
    end

    def lane = running_sop&.dig("sop").presence

    def label
      LANE_LABELS.fetch(lane) { lane.presence || FALLBACK_LABEL }
    end

    # The command behind the lane — the card's tooltip, so the operator can see
    # (and copy) exactly what is running without opening the session.
    def command = running_sop&.dig("cmd").presence

    # Last proof of life: the running lane's own timestamp, which the heartbeat
    # refreshes in place. Falls back to the attempt's start for the window
    # between `open` and the first lane's first beat.
    def heartbeat_at
      @heartbeat_at ||= parse_time(running_sop&.dig("at")) || started_at
    end

    def seconds_since_heartbeat = (@now - heartbeat_at).to_i

    def elapsed_seconds = [(@now - started_at).to_i, 0].max

    # STALLED is a claim about the RUNNER, not the tests: the process stopped
    # reporting. The card must not say "failed" — nobody knows the verdict, which
    # is exactly the operator's problem.
    def stalled? = seconds_since_heartbeat > STALE_AFTER

    def running? = !stalled?

    def state = stalled? ? :stalled : :running

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
