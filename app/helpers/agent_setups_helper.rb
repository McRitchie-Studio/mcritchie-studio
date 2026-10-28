# Labels for the Pending agents column of /agents (AgentSetup).
module AgentSetupsHelper
  KIND_LABELS = { "discord_bot" => "Discord bot" }.freeze

  # [label, tone] per status. The tone picks the badge's colours; each label
  # says plainly whose turn it is.
  STATUS_BADGES = {
    "pending" => [ "Your turn", "warning" ],
    "checking" => [ "Checking", "primary" ],
    "verifying" => [ "Waiting for Steffon to verify", "primary" ],
    "needs_attention" => [ "Needs attention", "danger" ],
    "ready" => [ "Ready", "success" ],
    "closed" => [ "Closed", "neutral" ]
  }.freeze

  BADGE_TONES = {
    "warning" => "bg-warning/10 text-warning-ink border-warning/40",
    "primary" => "bg-primary/10 text-primary-ink border-primary/40",
    "danger" => "bg-danger/10 text-danger-ink border-danger/40",
    "success" => "bg-success/10 text-success-ink border-success/40",
    "neutral" => "bg-surface-alt text-secondary border-strong"
  }.freeze

  def agent_setup_kind_label(setup) = KIND_LABELS.fetch(setup.kind, setup.kind.humanize)
  def agent_setup_status_label(setup) = STATUS_BADGES.fetch(setup.status, [ setup.status.humanize ]).first

  def agent_setup_badge(setup)
    label, tone = STATUS_BADGES.fetch(setup.status, [ setup.status.humanize, "neutral" ])
    tag.span(label, class: "badge text-xs shrink-0 self-start #{BADGE_TONES.fetch(tone)}",
                    data: { test: "agent-setup-badge", status: setup.status })
  end

  def agent_setup_stamp(time)
    time&.in_time_zone("America/Denver")&.strftime("%b %-d, %-l:%M %p %Z")
  end
end
