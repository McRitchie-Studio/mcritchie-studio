# frozen_string_literal: true

require "json"

# CertEmission — the best-effort durable-record emits the two G1 cert gates
# (bin/fast-check, bin/full-suite-check) used to carry byte-identical copies of:
# the GateRun markers (open / per-lane sop / close --failed via bin/gate), the
# "cert" checkpoint TaskEvent bounding the Local Certification phase, and the
# checks_run read that lets a green cert MERGE its evidence line (bin/task
# update --checks REPLACES the whole list).
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

  # The task's current checks_run (Array), or nil if it can't be read — so the
  # caller can MERGE new evidence into it. nil is the "don't risk wiping it"
  # signal, distinct from [] (a task with none yet).
  def fetch_checks(task_bin, slug)
    out = IO.popen([task_bin, "show", slug, "--json"], err: File::NULL, &:read)
    return nil unless $?.success?

    record = JSON.parse(out)
    Array(record.dig("metadata", "devops", "checks_run"))
  rescue JSON::ParserError, SystemCallError
    nil
  end

  # Read the task's checks_run BACK after an evidence write and return the lines
  # from `expected` that did NOT persist — [] when every line landed, nil when
  # the read-back itself failed (UNVERIFIABLE, distinct from a confirmed loss).
  # The cert scripts use this so their "preserved" claim is about board state
  # they have SEEN, never a declaration (the 2026-07-20 wipe printed "tier tags
  # preserved" over a write that had lost the builder's tier lines).
  def missing_after_write(task_bin, slug, expected)
    persisted = fetch_checks(task_bin, slug)
    return nil if persisted.nil?

    Array(expected).map(&:to_s) - persisted.map(&:to_s)
  end
end
