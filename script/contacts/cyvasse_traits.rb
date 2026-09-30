# Runs ON THE CYVASSE APP, read-only (task contact-traits-from-cyvasse).
# Prints a `CYVT,`-prefixed CSV of each player's traits (a header row, then one
# row per player with an email) for the hub's contacts:import_cyvasse_traits to
# store on contacts as traits["cyvasse"]. The prefix lets the pipe drop
# Heroku's and Rails' own log lines; stderr gets a count, never a row.
#
# Who: every account with an email that is not a Play Now guest, not a
# computer player (User::COMPUTER_LEGACY_IDS), and not merged into another.
#
#   games           matches the player actually PLAYED: at least one move was
#                   made, whatever the status or opponent (person or computer,
#                   legacy or new). An unanswered challenge, a match accepted
#                   but never started, and one that expired before play are
#                   not games (cyvasse's Leaderboard: "A match that expired
#                   before play is not a game"). A legacy match the import
#                   closed as "abandoned" counts only if it had a move.
#   finished_games  the games that ended with a result: king, resigned,
#                   forfeit or draw (Leaderboard::COUNTED_ENDINGS). Always a
#                   part of `games`, so a forfeit or resignation before the
#                   first move is in neither.
#   wins, losses    the account's record (users.wins/losses), which is what
#                   the all-time leaderboard shows
#   joined_on       users.created_at (the legacy import carried it over)
#   last_active_on  GREATEST(users.updated_at, the last move of a game the
#                   player played); a challenge nobody answered moves nothing
#   all_time_rank   the player's place on /leaderboard?board=all-time: the
#                   same people (User.ranked_players with a win) in the same
#                   order as Leaderboard.all_time (wins, fewest losses, oldest
#                   account, id). Blank for a player with no win or no username.
#   synced_at       when this script read the database
#
# WHY last_move AND NOT turn. "A move was made" is `last_move` being set. The
# two apps count `turn` differently: a new match starts at turn 1 before
# anyone moves (CyvasseRules::Game#start!), while a legacy match reads 1 after
# its first move. Measured on production 2026-09-30 (counts only): every match
# at turn 2+ has a last_move, a legacy turn-0 match never does, a legacy turn-1
# match always does, and a new turn-1 match never does.
#
# The full pipe (cyvasse -> hub, no player row ever printed) is in
# docs/email-delivery.md. To a local file instead:
#
#   heroku run -a cyvasse --no-tty -- bash -c 'cat > /tmp/a.rb; bin/rails runner /tmp/a.rb' \
#     < script/contacts/cyvasse_traits.rb | grep '^CYVT,' | cut -c6- > tmp/cyvasse-traits.csv
#
# The hub's test (test/integration/cyvasse_traits_script_test.rb) loads this file
# without running it and checks CyvasseTraits.sql against cyvasse-shaped tables.
require "csv"

module CyvasseTraits
  HEADER = %w[email username games finished_games wins losses joined_on last_active_on all_time_rank synced_at].freeze

  # computers: the computer players' legacy ids (a Range).
  # results:   the finish reasons that are a result (king resigned forfeit draw).
  def self.sql(computers:, results:, quote:)
    not_computer = "(legacy_id IS NULL OR legacy_id NOT BETWEEN #{Integer(computers.first)} AND #{Integer(computers.last)})"
    <<~SQL
      WITH ranked AS (
        SELECT id, ROW_NUMBER() OVER (ORDER BY wins DESC, losses ASC, created_at ASC, id ASC) AS rank
        FROM users
        WHERE guest = FALSE AND username IS NOT NULL AND username <> '' AND wins > 0 AND #{not_computer}
      ),
      played_matches AS (
        SELECT id, home_user_id, away_user_id, finish_reason, time_of_last_move FROM matches
        WHERE COALESCE(last_move, '') <> ''
      ),
      seats AS (
        SELECT id AS match_id, home_user_id AS user_id, finish_reason, time_of_last_move FROM played_matches
        UNION
        SELECT id, away_user_id, finish_reason, time_of_last_move FROM played_matches
      ),
      played AS (
        SELECT user_id,
               COUNT(*) AS games,
               COUNT(*) FILTER (WHERE finish_reason IN (#{results.map { |r| quote.call(r.to_s) }.join(", ")})) AS finished_games,
               MAX(time_of_last_move) AS last_move_at
        FROM seats GROUP BY user_id
      )
      SELECT users.email, users.username,
             COALESCE(played.games, 0), COALESCE(played.finished_games, 0),
             users.wins, users.losses, users.created_at,
             GREATEST(users.updated_at, played.last_move_at), ranked.rank
      FROM users
      LEFT JOIN played ON played.user_id = users.id
      LEFT JOIN ranked ON ranked.id = users.id
      WHERE users.email IS NOT NULL AND users.email <> '' AND users.guest = FALSE
        AND users.merged_into_id IS NULL AND #{not_computer.gsub("legacy_id", "users.legacy_id")}
      ORDER BY users.id
    SQL
  end

  # One CSV line per player (the header first), without the CYVT, prefix.
  def self.lines(connection, computers:, results:, synced_at: Time.now.utc)
    date = ->(value) { value && Time.zone.parse(value.to_s)&.to_date&.iso8601 }
    stamp = synced_at.utc.iso8601
    rows = connection.select_rows(sql(computers:, results:, quote: connection.method(:quote)))
    [ HEADER.to_csv ] + rows.map do |email, username, games, finished, wins, losses, created, active, rank|
      [ email, username, games, finished, wins, losses, date.call(created), date.call(active), rank, stamp ].to_csv
    end
  end
end

# Run only under `bin/rails runner` (which sets $0 to this file), never when a
# test loads it.
if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  $stdout.sync = true
  lines = CyvasseTraits.lines(ActiveRecord::Base.connection, computers: User::COMPUTER_LEGACY_IDS,
                                                             results: Leaderboard::COUNTED_ENDINGS)
  lines.each { |line| puts "CYVT,#{line}" }
  with_games = lines.drop(1).count { |line| CSV.parse_line(line)[2].to_i.positive? }
  warn "cyvasse_traits: #{lines.size - 1} players, #{with_games} with a game"
end
