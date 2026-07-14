# frozen_string_literal: true

# Renders the two facts a claimed build card must keep separate:
#
#   LIVENESS — "a terminal is painting" (the ClaimLease heartbeat, renewed by
#              bin/statusline every ~5s). It survives a wedged agent.
#   PROGRESS — "this task last produced a durable artifact N ago" (a TaskEvent or
#              a GateRun — evidence that work actually landed).
#
# The board used to show only the first and let readers infer the second. It never
# meant that: on 2026-07-13 a session sat 28 minutes producing nothing while its
# lease stayed green. These helpers state the progress fact in words, and refuse to
# dress an ABSENCE of evidence as trouble — an unknown progress age reads as
# "no artifact yet", never as a fault.
module ClaimProgressHelper
  # "live · progress 28m ago (cert failed)" — the one-line card summary.
  def claim_progress_summary(task, seconds = task.progress_seconds_ago)
    return "live · no durable artifact yet" if seconds.nil?

    label = task.last_progress_label.to_s
    detail = label.empty? ? "" : " (#{label})"
    "live · progress #{claim_progress_age(seconds)} ago#{detail}"
  end

  # The hover tooltip spells out what the pulsing dot does and does NOT attest.
  def claim_progress_title(task, seconds = task.progress_seconds_ago)
    lines = ["A terminal is live on this task (heartbeat ~#{task.claim_heartbeat_seconds_ago}s ago). " \
             "That attests the TERMINAL is alive — not that the agent is progressing."]

    lines << if seconds.nil?
               "No durable artifact recorded yet (no stage move, cert, or gate)."
             else
               "Last durable progress: #{claim_progress_age(seconds)} ago" \
                 "#{task.last_progress_label.present? ? " — #{task.last_progress_label}" : ""}."
             end

    if task.claim_progress_quiet?
      lines << "Held, but nothing has landed in a long time. Informational only — " \
               "nothing is reclaimed, and long builds legitimately go quiet."
    end

    lines.join(" ")
  end

  # One formatter, in ClaimLease, shared with the claim gate bin/task prints. The
  # card and the gate state the SAME fact; they must not be able to word it
  # differently.
  def claim_progress_age(seconds)
    ClaimLease.humanize_age(seconds)
  end
end
