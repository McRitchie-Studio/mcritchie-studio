# frozen_string_literal: true

# The dream loop's marks on /dreams (docs/agents/modules/dream.md, Act 4): a
# dream's heat, its grade, and the KPI strip's numbers.
module DreamLoopHelper
  # Fires at or over which a dream reads warm, then hot.
  HEAT_LEVELS = { "hot" => 5, "warm" => 1 }.freeze
  HEAT_CLASSES = {
    "hot" => "bg-danger/10 text-danger-ink border-danger/40",
    "warm" => "bg-warning/10 text-warning-ink border-warning/40",
    "cold" => "bg-surface-alt text-muted border-subtle"
  }.freeze

  # "hot", "warm" or "cold", by all-time fires.
  def dream_heat_level(fires)
    HEAT_LEVELS.find { |_, floor| fires.to_i >= floor }&.first || "cold"
  end

  def dream_heat_classes(fires) = HEAT_CLASSES.fetch(dream_heat_level(fires))

  # "graded 1.5 (4)", or nil before any grade.
  def dream_grade_label(summary)
    return nil if summary.nil? || summary.count.zero?

    "graded #{format("%.1f", summary.mean)} (#{summary.count})"
  end

  # A KPI value, or an em dash before there is data.
  def dream_kpi(value, suffix = "")
    value.nil? ? "—" : "#{value}#{suffix}"
  end
end
