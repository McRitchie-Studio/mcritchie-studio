# Runs ON THE CYVASSE APP, read-only (task verify-contacts-with-zerobounce).
# Prints one `CYV,<email>,<last_active_at>` line per player with an email, for
# contacts:verify to rank the legacy list most recently active first. The CYV,
# prefix lets the pipe drop Heroku's and Rails' own log lines.
#
# The recency signal is GREATEST(users.updated_at, the player's last match
# move). The legacy import carried the old app's updated_at over unchanged, and
# in the old app that column tracked its `last_active` stamp: measured against
# the 2026-09-25 backup, 17,104 of 18,789 players are within a day of it, 1,682
# of the rest are LATER (never earlier than 3), and the top 10,000 by each agree
# on 9,984. `last_active` itself was not imported. A player's last match move
# (matches.time_of_last_move, also imported) and any play on the new app keep
# the value current.
#
#   heroku run -a cyvasse --no-tty -- bash -c 'cat > /tmp/a.rb; bin/rails runner /tmp/a.rb' \
#     < script/contacts/cyvasse_last_active.rb | grep '^CYV,' | cut -c5- > tmp/cyvasse-last-active.csv
sql = <<~SQL
  WITH last_move AS (
    SELECT user_id, MAX(at) AS at FROM (
      SELECT home_user_id AS user_id, time_of_last_move AS at FROM matches
      UNION ALL
      SELECT away_user_id, time_of_last_move FROM matches
    ) moves GROUP BY user_id
  )
  SELECT users.email, GREATEST(users.updated_at, last_move.at) AS last_active_at
  FROM users LEFT JOIN last_move ON last_move.user_id = users.id
  WHERE users.email IS NOT NULL AND users.email <> '' AND users.guest = FALSE
SQL

require "csv"
$stdout.sync = true
count = 0
ActiveRecord::Base.connection.select_rows(sql).each do |email, at|
  puts "CYV,#{[ email, Time.zone.parse(at.to_s)&.utc&.iso8601 ].to_csv}"
  count += 1
end
warn "cyvasse_last_active: #{count} players"
