# frozen_string_literal: true

# The LOUD block a reviewer sees before merging a task that still carries an open
# operator-approval request (approval_status `waiting`).
#
# THE DECISION it serves (Mr. McRitchie, 2026-09-10, surface-waiting-request-at-merge):
# SURFACE IT, DO NOT BLOCK. Review may merge while a request is waiting; nothing
# refuses. But the question must reach the person merging, with the facts to act on:
# who asked, when, which page, and the note that asked. Before this, no review tool
# read approval_status at all, and the move to `reviewed` settled the request to
# `none` in silence.
#
# INFORMATION, NEVER A GATE. Every caller prints these lines and carries on with the
# exit status it had before. Pure Ruby with no Rails, so bin/task, bin/pr-review and
# bin/review-autopilot can all load it.
module ApprovalRequestNotice
  WAITING = "waiting"
  NOTE_LIMIT = 280

  module_function

  # The devops hash from either task shape: the board API's (metadata.devops) or the
  # flattened one bin/pr-review passes around (devops at the top level).
  def devops_of(task)
    return {} unless task.is_a?(Hash)

    devops = task["devops"] || task.dig("metadata", "devops")
    devops.is_a?(Hash) ? devops : {}
  end

  def waiting?(task)
    devops_of(task)["approval_status"].to_s.strip == WAITING
  end

  # [] unless the task is waiting, so a caller can print the result unconditionally.
  # `note` is the text of the handoff note that asked, when the caller has it.
  def lines(task, note: nil)
    return [] unless waiting?(task)

    devops = devops_of(task)
    slug = task["slug"].to_s
    [
      "!! OPERATOR APPROVAL STILL WAITING - information, not a gate: merging is allowed.",
      "   asked by: #{present(devops["approval_requested_by"]) || "unknown (no setter on record)"}" \
      "   at: #{present(devops["approval_requested_at"]) || "unrecorded"}",
      "   local demo: #{present(devops["local_url"]) || "none recorded"}",
      "   the note that asked: #{note_text(note)}",
      "   Merging settles it to none and leaves a note addressed to the setter.",
      "   Mr. McRitchie can still answer: bin/task update #{slug} --approval approved " \
      "(or --approval changes_requested)."
    ]
  end

  def note_text(note)
    text = present(note)
    return "no handoff note on record" unless text

    flat = text.gsub(/\s+/, " ")
    flat.length > NOTE_LIMIT ? "#{flat[0, NOTE_LIMIT - 3]}..." : flat
  end

  def present(value)
    text = value.to_s.strip
    text.empty? ? nil : text
  end
end
