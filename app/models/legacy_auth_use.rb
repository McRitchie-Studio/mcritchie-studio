# The legacy-use census (docs/agents/system/agent-sessions-design.md, section 8):
# every API request the shared secret authenticated, counted per day by endpoint
# and by caller. It holds no token, no secret and no request body. The shared
# token stops writing only after this census reads zero on production for the
# period the operator chooses; `bin/rails agent_auth:legacy_census` prints it.
#
# `endpoint` is the action ("PATCH api/v1/tasks#update"), or "POST
# api/v1/auth#create" for an exchange of the secret itself. `caller` is the script
# the request names in X-Agent-Caller ("bin/task", "turf-monster/sync_athletes"),
# which the caller asserts and the board uses for counting only; a request that
# names none is counted as `unlabelled`, with its user agent's product name.
class LegacyAuthUse < ApplicationRecord
  CALLER_HEADER = "X-Agent-Caller".freeze
  CALLER = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]{0,63}\z}
  UNLABELLED = "unlabelled".freeze
  EXCHANGE = "POST api/v1/auth#create".freeze

  validates :day, :endpoint, :caller, :last_used_at, presence: true

  scope :since, ->(time) { where(day: time.to_date..) }

  # Count one use. Never raises: the census must not fail the request it counts.
  def self.record!(endpoint:, caller:, now: Time.current)
    upsert({ day: now.utc.to_date, endpoint: endpoint.to_s, caller: caller.to_s, uses: 1, last_used_at: now },
           unique_by: %i[day endpoint caller],
           on_duplicate: Arel.sql("uses = legacy_auth_uses.uses + 1, last_used_at = EXCLUDED.last_used_at"))
  rescue StandardError => e
    Rails.logger.warn("[agent-auth] legacy census not written (#{e.class})")
    nil
  end

  # The caller a request names, or `unlabelled (<user agent product>)`.
  def self.caller_for(request)
    named = request.headers[CALLER_HEADER].to_s.strip
    return named if named.match?(CALLER)

    product = request.user_agent.to_s[%r{\A[A-Za-z0-9._-]{1,24}}]
    product ? "#{UNLABELLED} (#{product})" : UNLABELLED
  end

  # The census over the last `days` days: one row per endpoint and caller, the
  # busiest first, as { endpoint:, caller:, uses:, last_used_at: }.
  def self.census(days: 7, now: Time.current)
    since(now.utc - (days - 1).days).group(:endpoint, :caller)
                                    .pluck(:endpoint, :caller, Arel.sql("SUM(uses)"), Arel.sql("MAX(last_used_at)"))
                                    .map { |endpoint, caller, uses, last| { endpoint: endpoint, caller: caller, uses: uses.to_i, last_used_at: last } }
                                    .sort_by { |row| [ -row[:uses], row[:endpoint], row[:caller] ] }
  end

  # Uses per day over the last `days` days, a zero for a day with none, oldest first.
  def self.by_day(days: 7, now: Time.current)
    first = now.utc.to_date - (days - 1)
    counts = where(day: first..).group(:day).sum(:uses)
    (first..now.utc.to_date).to_h { |day| [ day, counts[day].to_i ] }
  end
end
