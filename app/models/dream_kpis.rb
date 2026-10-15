# frozen_string_literal: true

# The /dreams header strip (docs/agents/modules/dream.md, Act 4): four numbers that
# say whether the loop is working. Each reads a bounded window on an indexed column.
#
#   fire rate         dream fires per session over the last WINDOW. The proxy for
#                     "sessions a dream loads in" is every session that opened an
#                     activity in the window, since every session loads the
#                     platform layer.
#   mean grade        the mean of the grades sessions gave in the window (0 to 2).
#   swaps per week    swaps and adds Alex approved over the last SWAP_WEEKS weeks,
#                     per week.
#   approval latency  the median days from a dream's proposal to Alex's click, over
#                     the newest LATENCY_ROWS approvals. dream_approvals holds the
#                     click; the proposal date is the date that opens the dream's
#                     `source:` line (day resolution). An approval whose dream has no
#                     dated source is left out.
class DreamKpis
  WINDOW = 30.days
  SWAP_WEEKS = 4
  LATENCY_ROWS = 100

  attr_reader :fires, :sessions, :mean_grade, :grades, :swaps, :latency_days, :latency_count, :no_swaps

  def self.build(dreams, now: Time.current) = new(dreams, now: now)

  def initialize(dreams, now: Time.current)
    since = now - WINDOW
    @fires = AgentAction.where(kind: DreamHeat::KIND, occurred_at: since..).where.not(event_slug: nil).count
    @sessions = AgentActivity.where(opened_at: since..).distinct.count(:session_id)
    grades = DreamGrade.where(created_at: since..)
    @grades = grades.count
    @mean_grade = @grades.zero? ? nil : grades.average(:score).to_f.round(2)
    swap_since = now - SWAP_WEEKS.weeks
    @swaps = DreamSwap.where(approved_at: swap_since..).count
    @no_swaps = DreamSwap.where(in_slug: nil, created_at: swap_since..).count
    measure_latency(Array(dreams))
  end

  # Fires per session in the window; nil before any session.
  def fire_rate = @sessions.zero? ? nil : (@fires.to_f / @sessions).round(2)

  def swaps_per_week = (@swaps.to_f / SWAP_WEEKS).round(2)

  private

  def measure_latency(dreams)
    by_key = dreams.index_by { |dream| DreamApproval.key_for(dream) }
    days = DreamApproval.order(approved_at: :desc).limit(LATENCY_ROWS).filter_map do |row|
      proposed = (dream = by_key[row.key]) && DreamLoop.source_date(dream)
      proposed && [ (row.approved_at - proposed) / 1.day, 0 ].max
    end
    @latency_count = days.size
    @latency_days = days.empty? ? nil : median(days).round(1)
  end

  def median(values)
    sorted = values.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end
end
