# Runs ON THE CYVASSE APP, read-only (task first-game-feedback-survey).
# Prints a `CYVN,`-prefixed CSV of the players who have played on the rebuilt
# Cyvasse (a header row, then one row per player) for the hub's
# contacts:tag_new_stack_players to tag as cyvasse-new-stack-player. The
# prefix lets the pipe drop Heroku's and Rails' own log lines; stderr gets a
# count, never a row.
#
# Who: every account with an email that is not a Play Now guest, not a
# computer player (User::COMPUTER_LEGACY_IDS) and not merged into another,
# with at least one NEW-STACK GAME: a match created on or after the relaunch
# (SINCE, 2026-09-28) that is not a legacy import (legacy_id IS NULL) and had
# a move made (last_move set, the same "a game was played" rule as
# script/contacts/cyvasse_traits.rb, which explains why not `turn`).
#
#   email               the account's email
#   first_new_game_on   the date (UTC) the first such match was created
#   new_games           how many such matches the player was seated in
#
# The full pipe (cyvasse -> hub, no player row ever printed) is in
# docs/email-delivery.md. To a local file:
#
#   heroku run -a cyvasse --no-tty -- bash -c 'cat > /tmp/a.rb; bin/rails runner /tmp/a.rb' \
#     < script/contacts/cyvasse_new_stack_players.rb | grep '^CYVN,' | cut -c6- > tmp/cyvasse-new-stack.csv
#
# The hub's test (test/integration/cyvasse_new_stack_players_script_test.rb)
# loads this file without running it and checks the SQL against cyvasse-shaped
# tables.
require "csv"

module CyvasseNewStackPlayers
  HEADER = %w[email first_new_game_on new_games].freeze unless const_defined?(:HEADER)
  SINCE = "2026-09-28".freeze unless const_defined?(:SINCE)

  # computers: the computer players' legacy ids (a Range).
  def self.sql(computers:, since:, quote:)
    not_computer = "(users.legacy_id IS NULL OR users.legacy_id NOT BETWEEN #{Integer(computers.first)} AND #{Integer(computers.last)})"
    <<~SQL
      WITH new_games AS (
        SELECT id, home_user_id, away_user_id, created_at FROM matches
        WHERE COALESCE(last_move, '') <> '' AND legacy_id IS NULL AND created_at >= #{quote.call(since)}
      ),
      seats AS (
        SELECT id AS match_id, home_user_id AS user_id, created_at FROM new_games
        UNION
        SELECT id, away_user_id, created_at FROM new_games
      )
      SELECT users.email, MIN(seats.created_at)::date, COUNT(DISTINCT seats.match_id)
      FROM seats
      JOIN users ON users.id = seats.user_id
      WHERE users.email IS NOT NULL AND users.email <> '' AND users.guest = FALSE
        AND users.merged_into_id IS NULL AND #{not_computer}
      GROUP BY users.id, users.email
      ORDER BY users.id
    SQL
  end

  # One CSV line per player (the header first), without the CYVN, prefix.
  def self.lines(connection, computers:, since: SINCE)
    rows = connection.select_rows(sql(computers:, since:, quote: connection.method(:quote)))
    [ HEADER.to_csv ] + rows.map do |email, first_on, games|
      [ email, Date.parse(first_on.to_s).iso8601, games ].to_csv
    end
  end
end

# Run only under `bin/rails runner` (which sets $0 to this file), never when a
# test loads it.
if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  $stdout.sync = true
  lines = CyvasseNewStackPlayers.lines(ActiveRecord::Base.connection, computers: User::COMPUTER_LEGACY_IDS)
  lines.each { |line| puts "CYVN,#{line}" }
  warn "cyvasse_new_stack_players: #{lines.size - 1} players with a new-stack game since #{CyvasseNewStackPlayers::SINCE}"
end
