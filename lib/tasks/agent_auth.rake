# frozen_string_literal: true

# The legacy-use census, for the operator
# (docs/agents/system/agent-sessions-design.md, section 8).
#
#   bin/rails agent_auth:legacy_census            the last 7 days
#   bin/rails agent_auth:legacy_census DAYS=30
#
# It prints every endpoint and caller the shared secret authenticated, a total
# per day, and the last use. It never prints a token: the table holds none. The
# shared token stops writing only after this reads zero on production for the
# period the operator chooses.
namespace :agent_auth do
  desc "Print the legacy shared-secret use census (DAYS=7): uses by endpoint and caller, and per day"
  task legacy_census: :environment do
    days = Integer(ENV["DAYS"].presence || "7", 10, exception: false)
    abort "agent_auth:legacy_census: DAYS must be a whole number from 1 to 365, got #{ENV["DAYS"].inspect}" unless days&.between?(1, 365)

    rows = LegacyAuthUse.census(days: days)
    by_day = LegacyAuthUse.by_day(days: days)
    total = by_day.values.sum
    puts "Legacy shared-secret use, last #{days} day(s) (UTC): #{total} request(s)"
    if rows.empty?
      puts "ZERO: no request was authenticated by the shared secret in this period."
    else
      width = rows.map { |row| row[:endpoint].length }.max
      rows.each do |row|
        puts format("%8d  %-#{width}s  %-32s  last %s", row[:uses], row[:endpoint], row[:caller], row[:last_used_at].utc.iso8601)
      end
    end
    puts "By day: #{by_day.map { |day, uses| "#{day} #{uses}" }.join(" · ")}"
  end
end
