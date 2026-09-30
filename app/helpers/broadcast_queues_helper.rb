# Display helpers for the staged email queue (task staged-email-queue).
module BroadcastQueuesHelper
  STAGED_LABELS = {
    "staged" => "Staged", "approved" => "Approved", "queued" => "Queued to send",
    "sent" => "Sent", "skipped" => "Skipped", "cancelled" => "Cancelled"
  }.freeze

  # A row's display status: an approved row handed to the send job is "queued".
  def staged_status_key(row)
    row.queued? ? "queued" : row.status
  end

  def staged_status_label(key)
    STAGED_LABELS.fetch(key.to_s) { key.to_s.humanize }
  end

  # Pill classes: held rows read neutral, approved amber (armed), sent green,
  # skipped red, cancelled muted.
  def staged_status_classes(key)
    case key.to_s
    when "approved", "queued" then "bg-warning/10 text-warning-ink border-warning/40"
    when "sent" then "bg-success/10 text-success-ink border-success/40"
    when "skipped" then "bg-danger/10 text-danger-ink border-danger/40"
    when "cancelled" then "bg-surface-alt text-muted border-subtle"
    else "bg-primary/10 text-primary border-primary/40"
    end
  end
end
