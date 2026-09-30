# Runs ON THE CYVASSE APP, read-only (task contact-traits-from-cyvasse).
# Prints a `CYVT,`-prefixed CSV of each player's traits (a header row, then one
# row per player with an email) for the hub's contacts:import_cyvasse_traits to
# store on contacts as traits["cyvasse"]. The prefix lets the pipe drop
# Heroku's and Rails' own log lines; stderr gets a count, never a row.
#
# Who: every account with an email that is not a Play Now guest, not a
# computer player (User::COMPUTER_LEGACY_IDS), and not merged into another.
#
#   games           every match the player sat in, home or away, against a
#                   person or a computer, legacy or new, whatever its status
#   finished_games  those whose match_status is finished
#   wins, losses    the account's record (users.wins/losses), which is what
#                   the all-time leaderboard shows
#   joined_on       users.created_at (the legacy import carried it over)
#   last_active_on  GREATEST(users.updated_at, the player's last match move),
#                   the recency signal script/contacts/cyvasse_last_active.rb
#                   explains
#   all_time_rank   the player's place on /leaderboard?board=all-time: the
#                   same people (User.ranked_players with a win) in the same
#                   order as Leaderboard.all_time (wins, fewest losses, oldest
#                   account, id). Blank for a player with no win or no username.
#   synced_at       when this script read the database
#
# The full pipe (cyvasse -> hub, no player row ever printed) is in
# docs/email-delivery.md. To a local file instead:
#
#   heroku run -a cyvasse --no-tty -- bash -c 'cat > /tmp/a.rb; bin/rails runner /tmp/a.rb' \
#     < script/contacts/cyvasse_traits.rb | grep '^CYVT,' | cut -c6- > tmp/cyvasse-traits.csv
computers = User::COMPUTER_LEGACY_IDS
sql = <<~SQL
  WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY wins DESC, losses ASC, created_at ASC, id ASC) AS rank
    FROM users
    WHERE guest = FALSE AND username IS NOT NULL AND username <> '' AND wins > 0
      AND (legacy_id IS NULL OR legacy_id NOT BETWEEN #{computers.first.to_i} AND #{computers.last.to_i})
  ),
  seats AS (
    SELECT id AS match_id, home_user_id AS user_id, match_status, time_of_last_move FROM matches
    UNION
    SELECT id, away_user_id, match_status, time_of_last_move FROM matches
  ),
  played AS (
    SELECT user_id,
           COUNT(*) AS games,
           COUNT(*) FILTER (WHERE match_status = #{ActiveRecord::Base.connection.quote(Match::FINISHED)}) AS finished_games,
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
    AND users.merged_into_id IS NULL
    AND (users.legacy_id IS NULL OR users.legacy_id NOT BETWEEN #{computers.first.to_i} AND #{computers.last.to_i})
  ORDER BY users.id
SQL

require "csv"
$stdout.sync = true
synced_at = Time.current.utc.iso8601
date = ->(value) { value && Time.zone.parse(value.to_s)&.to_date&.iso8601 }

puts "CYVT,#{%w[email username games finished_games wins losses joined_on last_active_on all_time_rank synced_at].to_csv}"
count = with_games = 0
ActiveRecord::Base.connection.select_rows(sql).each do |email, username, games, finished, wins, losses, created, active, rank|
  puts "CYVT,#{[ email, username, games, finished, wins, losses, date.call(created), date.call(active), rank, synced_at ].to_csv}"
  count += 1
  with_games += 1 if games.to_i.positive?
end
warn "cyvasse_traits: #{count} players, #{with_games} with a game"
