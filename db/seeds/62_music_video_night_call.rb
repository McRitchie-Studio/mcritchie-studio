# The cast panel's demo: Steve Aoki's Night Call with its seven unlabelled people
# (db/seeds/data/night_call_cast.rb). Local only: the stills live in the dev bucket.
return unless Rails.env.local?

load Rails.root.join("db/seeds/data/night_call_cast.rb").to_s
video = NightCallCast.seed!
safe_puts "  Music video #{video.slug}: #{video.video_performers.count} performers"
