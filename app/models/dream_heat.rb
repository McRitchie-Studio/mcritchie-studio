# frozen_string_literal: true

# The /dreams heat signal: how often each dream shaped a decision.
#
# `bin/dream fired <slug> --decision "..."` records one AgentAction of kind
# DREAM_FIRED on the session's open activity, with the dream's slug in event_slug
# and the decision as its summary. This reads them back in two queries: a count per
# dream, and the newest few decisions per dream. Those rows are kept past the
# 45-day action retention (AgentActionRetentionJob), so the count is all-time.
class DreamHeat
  KIND = "dream_fired"
  RECENT = 3

  Decision = Struct.new(:summary, :occurred_at, :task_slug, :mascot, keyword_init: true)

  def self.build(slugs = nil) = new(slugs)

  def initialize(slugs = nil)
    scope = AgentAction.where(kind: KIND).where.not(event_slug: nil)
    scope = scope.where(event_slug: slugs) if slugs
    @counts = scope.group(:event_slug).count
    @recent = recent_decisions(scope)
  end

  def count(slug) = @counts.fetch(slug.to_s, 0)

  def decisions(slug) = @recent.fetch(slug.to_s, [])

  def total = @counts.values.sum

  private

  # The newest RECENT decisions per dream, in one window-ranked statement.
  def recent_decisions(scope)
    ranked = scope.select("id, ROW_NUMBER() OVER (PARTITION BY event_slug ORDER BY occurred_at DESC, id DESC) AS heat_rank")
    newest = AgentAction.from(ranked, :ranked).select("ranked.id").where("ranked.heat_rank <= ?", RECENT)
    AgentAction.where(id: newest).order(occurred_at: :desc, id: :desc)
               .pluck(:event_slug, :summary, :occurred_at, :task_slug, :mascot)
               .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(slug, summary, at, task, mascot), out|
                 out[slug] << Decision.new(summary: summary, occurred_at: at, task_slug: task, mascot: mascot)
               end
  end
end
