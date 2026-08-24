# frozen_string_literal: true

require "json"

# CertEmission — the durable-record emits the two G1 cert gates (bin/fast-check,
# bin/full-suite-check) used to carry byte-identical copies of: the GateRun
# markers (open / per-lane sop / close --failed via bin/gate), the "cert"
# checkpoint TaskEvent bounding the Local Certification phase, and the checks_run
# reads that BOUND a green cert's evidence write — the baseline before it
# (#fetch_checks) and the verification after it (#missing_after_write).
#
# The certs do NOT merge. Each sends ONLY the evidence line it owns and lets the
# write funnel merge against the board's CURRENT state (lib/cert_evidence.rb);
# a cert that read, merged, and resent the whole list is what let a stale
# snapshot replace newer tier lines. These reads exist to VERIFY that write,
# not to compute it.
#
# PARAMETERIZED, not unified: each gate passes its own gate_bin/task_bin (they
# keep their separate FAST_CHECK_*/fixed-path seams), and the lane RUNNERS stay
# per-script — their PASS output formats and full-suite's emit_test_scope
# telemetry genuinely differ.
#
# Everything here is fire-and-forget: a board/gate blip never breaks a cert.
module CertEmission
  module_function

  # One bin/gate invocation; no-op without a task slug (--print runs).
  def emit_gate(gate_bin, slug, *args)
    return if slug.to_s.strip.empty?

    system(gate_bin, *args, out: File::NULL, err: File::NULL)
  rescue StandardError
    nil
  end

  # Mark a lane RUNNING on the open g1_cert attempt — emitted BEFORE the lane
  # starts, and re-emitted as a heartbeat while it runs (GateRun.append_sop!
  # supersedes the prior running row, so beats do not stack).
  #
  # This is what lets the board name the lane a building task is inside, and —
  # because the beat carries a fresh timestamp — tell a live cert from one whose
  # process was killed. Fire-and-forget like every other emit here: a board blip
  # must never break a cert.
  def emit_gate_sop_running(gate_bin, slug, label, cmd)
    emit_gate(gate_bin, slug, "sop", "task", slug, "g1_cert",
              "--sop", label, "--cmd", cmd.to_s, "--result", "running")
  end

  # Beat `running` for `label` every `interval` seconds until the returned
  # Heartbeat is stopped. The caller MUST stop it in an ensure block, with
  # `stop_heartbeat` — see run_lane.
  #
  # A lane can legitimately run for many minutes (a fast-check has been observed
  # at 7+), which is far longer than the staleness window the board uses to spot a
  # dead runner. Without a beat mid-lane, every long-but-healthy lane would render
  # as stalled; with one, "stalled" means what it says.
  def heartbeat_thread(gate_bin, slug, label, cmd, interval: 40)
    return nil if slug.to_s.strip.empty?

    Heartbeat.new(interval: interval) { emit_gate_sop_running(gate_bin, slug, label, cmd) }
  rescue StandardError
    nil
  end

  # Stop a beat and WAIT for it, so the lane's terminal row is emitted after the
  # last `running` row rather than racing it. No-op on nil (a --print run).
  def stop_heartbeat(beat, join_timeout: Heartbeat::JOIN_TIMEOUT)
    beat&.stop(join_timeout: join_timeout)
  rescue StandardError
    nil
  end

  # A `running` beat that keeps its own shutdown ORDERED against the caller's
  # terminal emission.
  #
  # `Thread#kill` alone was not enough, and the gap is not theoretical. Each beat
  # shells `bin/gate` through `system`; killing a thread parked in that call
  # unwinds the THREAD but leaves the CHILD PROCESS running, so a `running` row
  # could land after the lane's pass/fail row — repainting a settled lane as live,
  # or (once the gate had closed) opening a phantom attempt the board renders as a
  # cert that never ends.
  #
  # So the emit and the stop take the same lock: `stop` cannot return while a beat
  # is in flight, and no beat can start once `stop` has been through. Wait, do not
  # kill — the child is the thing that has to finish, and killing the thread is
  # what strands it. The kill is kept only as the timeout's last resort.
  #
  # GateRun.append_sop! independently REFUSES a straggler that arrives anyway.
  # That belt is for the paths no ensure block can reach — SIGKILL above all —
  # and does not make this ordering optional: it is what keeps the row correct on
  # the path we DO control.
  class Heartbeat
    # A `bin/gate` call is a couple of HTTP requests with modest timeouts (the CLI
    # sets open 2s / read 10s). 15s is past the slowest honest one; a beat still
    # in flight after that is stuck, and the lane's verdict must not wait on it.
    JOIN_TIMEOUT = 15

    def initialize(interval:, &emit)
      @interval = interval
      @emit = emit
      @gate = Mutex.new
      @stopping = false
      @thread = Thread.new { beat_until_stopped }
    end

    # Trap-safe stop: no lock, no join. `Mutex#synchronize` RAISES in a trap
    # context, so the signal path cannot use #stop — it sets the flag (a plain
    # write is safe), kills the thread, and accepts that a child already in flight
    # may still land. GateRun.append_sop! drops it.
    def stop_now
      @stopping = true
      @thread.kill
      nil
    end

    def stop(join_timeout: JOIN_TIMEOUT)
      # Taking the lock WAITS OUT an emit already in flight, and setting the flag
      # under it means no further emit can start. Both halves of the ordering.
      @gate.synchronize { @stopping = true }
      begin
        @thread.wakeup
      rescue ThreadError
        nil # already dead — nothing to wake
      end
      return true if @thread.join(join_timeout)

      @thread.kill
      false
    end

    private

    def beat_until_stopped
      loop do
        sleep @interval
        break unless @gate.synchronize { @stopping ? false : (@emit.call || true) }
      end
    rescue StandardError
      nil # fire-and-forget, like every other emit here
    end
  end

  # One executed-SOP entry on the task's open g1_cert attempt.
  def emit_gate_sop(gate_bin, slug, label, cmd, ok, duration_ms)
    emit_gate(gate_bin, slug, "sop", "task", slug, "g1_cert",
              "--sop", label, "--cmd", cmd.to_s,
              "--result", ok ? "pass" : "fail",
              "--duration-ms", duration_ms.to_s)
  end

  # THE INTERRUPT PATH'S TERMINAL WRITE: settle the lane, then CLOSE the gate.
  #
  # Shared by both certs because it is the same duty and two copies would drift —
  # and the half that drifts is the one nobody is currently reading.
  #
  # WHY A CATCHABLE DEATH MUST CLOSE. `Cert::LocalCheck` reads an OPEN g1_cert
  # attempt carrying a `running` lane as a cert that is still going, and after
  # STALE_AFTER it calls that STALLED. That reading is right for a death we could
  # not witness — a SIGKILL, a lost machine — and wrong for a Ctrl-C, where we are
  # still executing and can simply say what happened. So the interrupt closes the
  # attempt: the card goes quiet (the marker is cleared, which is what the
  # acceptance asks for on success, failure, AND interrupt), and STALLED is left
  # meaning the one thing it can honestly mean.
  #
  # The lane is recorded FAILED, not merely absent, because that is the truth an
  # operator needs: the lane did not produce a verdict. `cause=interrupted` and
  # the signal ride along as gate metadata so the attempt says WHY it failed
  # rather than implying a red suite.
  def emit_interrupt_close(gate_bin, slug, label, cmd, signal, duration_ms)
    return if slug.to_s.strip.empty?

    emit_gate_sop(gate_bin, slug, label, cmd, false, duration_ms)
    emit_gate(gate_bin, slug, "close", "task", slug.to_s, "g1_cert", "--failed",
              "--meta", "cause=interrupted", "--meta", "signal=SIG#{signal}")
  end

  # The "cert" checkpoint TaskEvent (started/completed) bounding the task's
  # Local Certification testing phase.
  def emit_cert_checkpoint(task_bin, slug, status)
    return if slug.to_s.strip.empty?

    system(task_bin, "checkpoint", slug, "cert", "--status", status,
           out: File::NULL, err: File::NULL)
  rescue StandardError
    nil
  end

  # The task's current checks_run (Array) — the BASELINE a cert's read-back is
  # verified against, NOT input to a merge (the certs no longer merge; see the
  # module note above).
  #
  # nil means the board could not be read, and the callers treat it as ABORT, DO
  # NOT WRITE: a write whose preservation cannot afterwards be VERIFIED is exactly
  # the failure this gate exists to catch, so the cert refuses rather than
  # certifying blind (bin/fast-check + bin/full-suite-check both exit 1). That is
  # the INVERSE of the old contract, where nil meant "don't risk wiping it"
  # because the read fed a merge.
  #
  # nil is returned for an unreadable/unparseable response AND for a record with
  # no devops hash at all — "I did not find the shape I was looking for" is not
  # evidence of absence. Only a task that genuinely carries devops with no checks
  # yields [], so a bare [] can be trusted to mean "none to preserve".
  def fetch_checks(task_bin, slug)
    out = IO.popen([task_bin, "show", slug, "--json"], err: File::NULL, &:read)
    return nil unless $?.success?

    record = JSON.parse(out)
    devops = record.is_a?(Hash) ? record.dig("metadata", "devops") : nil
    return nil unless devops.is_a?(Hash)

    Array(devops["checks_run"])
  rescue JSON::ParserError, SystemCallError
    nil
  end

  # Read the task's checks_run BACK after an evidence write and return the lines
  # from `expected` that did NOT persist — [] when every line landed, nil when
  # the read-back itself failed (UNVERIFIABLE, distinct from a confirmed loss).
  # The cert scripts use this so their "preserved" claim is about board state
  # they have SEEN, never a declaration (the 2026-07-20 wipe printed "tier tags
  # preserved" over a write that had lost the builder's tier lines).
  # Counts MULTIPLICITY, not membership: Array#- would report a line as kept when
  # only one of its two copies survived, which is still a loss of a line the
  # builder recorded. Each expected occurrence must be matched by its own
  # persisted occurrence.
  def missing_after_write(task_bin, slug, expected)
    persisted = fetch_checks(task_bin, slug)
    return nil if persisted.nil?

    remaining = persisted.map(&:to_s).tally
    Array(expected).map(&:to_s).each_with_object([]) do |line, lost|
      if remaining.fetch(line, 0).positive?
        remaining[line] -= 1
      else
        lost << line
      end
    end
  end
end
