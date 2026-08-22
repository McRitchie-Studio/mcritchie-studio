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

  # Beat `running` for `label` every `interval` seconds until the returned thread
  # is killed. The caller MUST kill it in an ensure block — see run_lane.
  #
  # A lane can legitimately run for many minutes (a fast-check has been observed
  # at 7+), which is far longer than the staleness window the board uses to spot a
  # dead runner. Without a beat mid-lane, every long-but-healthy lane would render
  # as stalled; with one, "stalled" means what it says.
  def heartbeat_thread(gate_bin, slug, label, cmd, interval: 40)
    return nil if slug.to_s.strip.empty?

    Thread.new do
      loop do
        sleep interval
        emit_gate_sop_running(gate_bin, slug, label, cmd)
      end
    end
  rescue StandardError
    nil
  end

  # One executed-SOP entry on the task's open g1_cert attempt.
  def emit_gate_sop(gate_bin, slug, label, cmd, ok, duration_ms)
    emit_gate(gate_bin, slug, "sop", "task", slug, "g1_cert",
              "--sop", label, "--cmd", cmd.to_s,
              "--result", ok ? "pass" : "fail",
              "--duration-ms", duration_ms.to_s)
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
