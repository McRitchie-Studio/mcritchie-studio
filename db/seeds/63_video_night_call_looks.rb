# The looks demo: Night Call with a confirmed cast and two labelled test artists
# (db/seeds/data/night_call_looks.rb). Local only: the stills live in the dev bucket.
return unless Rails.env.local?

require Rails.root.join("db/seeds/data/night_call_looks.rb").to_s
video = NightCallLooks.seed!
safe_puts "  Music video #{video.slug}: cast confirmed, #{video.video_performers.where.not(artist_slug: nil).count} labelled"
