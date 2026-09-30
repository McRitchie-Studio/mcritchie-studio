# Display helpers for /contacts (task contacts-admin-page).
module ContactsHelper
  # Pill classes for a verification status: green is mailable, amber is a
  # risk a verified-only send skips, red is never mailed.
  def contact_status_classes(status)
    case status
    when "valid" then "bg-success/10 text-success-ink border-success/40"
    when "catch-all", "unknown" then "bg-warning/10 text-warning-ink border-warning/40"
    when *Contact::UNDELIVERABLE_STATUSES then "bg-danger/10 text-danger-ink border-danger/40"
    else "bg-surface-alt text-secondary border-subtle"
    end
  end

  # The bar colour for one row of the verification breakdown.
  def contact_status_bar(status)
    case status
    when "valid" then "bg-success"
    when "catch-all", "unknown" then "bg-warning"
    when *Contact::UNDELIVERABLE_STATUSES then "bg-danger"
    else "bg-surface-alt"
    end
  end

  def contact_status_label(status)
    { "catch-all" => "Catch-all", "do_not_mail" => "Do not mail", "unverified" => "Not yet verified" }
      .fetch(status.to_s) { status.to_s.humanize }
  end

  def contact_reason_label(reason)
    { "requested" => "Unsubscribed", "bounced" => "Hard bounce", "complained" => "Spam complaint",
      "verification" => "Failed verification" }.fetch(reason.to_s) { reason.to_s.humanize }
  end

  # A short timestamp with the full one on hover; a dash when never.
  def contact_time(time)
    return tag.span("—", class: "text-muted") if time.nil?

    tag.time(time.strftime("%b %-d, %H:%M"), datetime: time.iso8601, title: time.strftime("%b %-d, %Y %H:%M:%S %Z"))
  end
end
