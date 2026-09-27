module BroadcastAnalyticsHelper
  HEALTH = {
    green: { icon: "✓", word: "Healthy", classes: "border-success/40 bg-success/10 text-success-ink" },
    amber: { icon: "!", word: "Watch", classes: "border-warning/40 bg-warning/10 text-warning-ink" },
    red: { icon: "✕", word: "Over the limit", classes: "border-danger/40 bg-danger/10 text-danger-ink" },
    none: { icon: "–", word: "No sends yet", classes: "border-subtle bg-surface-alt text-secondary" }
  }.freeze

  GOAL_LABELS = {
    "signed_in" => "Signed in", "played_match" => "Played a match",
    "joined_newsletter" => "Joined the newsletter", "requested_app" => "Requested an app"
  }.freeze

  # A rate as a percent; small rates keep two decimals so 0.08% reads true.
  def analytics_pct(rate)
    return "—" if rate.nil?

    pct = rate * 100
    format(pct < 1 && pct.positive? ? "%.2f%%" : "%.1f%%", pct)
  end

  def analytics_health(status)
    HEALTH.fetch(status)
  end

  def analytics_goal_label(goal)
    GOAL_LABELS.fetch(goal, goal.to_s.humanize)
  end
end
