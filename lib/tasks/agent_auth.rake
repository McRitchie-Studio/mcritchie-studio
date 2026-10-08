# frozen_string_literal: true

# The legacy-use census, for the operator
# (docs/agents/system/agent-sessions-design.md, section 8).
#
#   bin/rails agent_auth:legacy_census            the last 7 days
#   bin/rails agent_auth:legacy_census DAYS=30
#
# It prints every endpoint and caller the shared secret authenticated, a total
# per day, and the last use. It never prints a token: the table holds none.
#
# The gate for retiring the shared token is the count OUTSIDE the mint doors
# (LegacyAuthUse::MINT_DOORS: the exchange of the secret and the requests that
# mint a login, which the secret keeps). The shared token stops writing only
# after that count reads zero on production for the period the operator chooses.
namespace :agent_auth do
  desc "Print the legacy shared-secret use census (DAYS=7): uses by endpoint and caller, and per day"
  task legacy_census: :environment do
    days = Integer(ENV["DAYS"].presence || "7", 10, exception: false)
    abort "agent_auth:legacy_census: DAYS must be a whole number from 1 to 365, got #{ENV["DAYS"].inspect}" unless days&.between?(1, 365)

    rows = LegacyAuthUse.census(days: days)
    by_day = LegacyAuthUse.by_day(days: days)
    total = by_day.values.sum
    outside = LegacyAuthUse.outside_mint_doors(days: days)
    puts "Legacy shared-secret use, last #{days} day(s) (UTC): #{total} request(s), #{outside} outside the mint doors"
    if outside.zero?
      puts "ZERO: no request outside the mint doors was authenticated by the shared secret in this period."
    else
      puts "NOT ZERO: #{outside} request(s) outside the mint doors still rode the shared secret. Each is marked * below."
    end
    width = rows.map { |row| row[:endpoint].length }.max
    rows.each do |row|
      mark = LegacyAuthUse::MINT_DOORS.include?(row[:endpoint]) ? " " : "*"
      puts format("%8d %s %-#{width}s  %-32s  last %s", row[:uses], mark, row[:endpoint], row[:caller], row[:last_used_at].utc.iso8601)
    end
    puts "By day: #{by_day.map { |day, uses| "#{day} #{uses}" }.join(" · ")}"
  end
end
