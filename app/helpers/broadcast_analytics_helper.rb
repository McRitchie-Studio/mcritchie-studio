module BroadcastAnalyticsHelper
  HEALTH = {
    green: { icon: "✓", word: "Healthy", classes: "border-success/40 bg-success/10 text-success-ink" },
    amber: { icon: "!", word: "Watch", classes: "border-warning/40 bg-warning/10 text-warning-ink" },
    red: { icon: "✕", word: "Over the limit", classes: "border-danger/40 bg-danger/10 text-danger-ink" },
    none: { icon: "–", word: "No sends yet", classes: "border-subtle bg-surface-alt text-secondary" }
  }.freeze

  GOAL_LABELS = {
    "signed_in" => "Signed in", "played_match" => "Played a match",
    "joined_newsletter" => "Joined the newsletter", "requested_app" => "Requested an app",
    "survey_completed" => "Answered a survey"
  }.freeze

  # A rate as a percent; small rates keep two decimals so 0.08% reads true.
  # A count with its share of delivered, as the four-style table shows it.
  def cyvasse_four_cell(count, rate)
    "#{number_with_delimiter(count)} · #{analytics_pct(rate)}"
  end

  def cyvasse_four_verdict_title(verdict)
    case verdict.state
    when :waiting then "Nothing sent yet"
    when :early then "Too early to call"
    when :close then "Too close to call"
    when :clear then "#{verdict.leader.name} is ahead"
    end
  end

  def cyvasse_four_verdict_note(verdict)
    case verdict.state
    when :waiting then "Results appear here as the first batch goes out."
    when :early then "#{verdict.leader.name} leads on #{verdict.metric}, but every style needs #{Broadcasts::CyvasseFourScoreboard::MIN_DELIVERED} delivered before the lead means much."
    when :close then "#{verdict.leader.name} leads on #{verdict.metric}, but the gap could still be chance. Send more before picking a winner."
    when :clear then "The lead on #{verdict.metric} is unlikely to be chance, at about 95% confidence."
    end
  end

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
