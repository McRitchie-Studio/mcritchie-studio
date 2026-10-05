# The recast picker's demo: a synthetic cinematic video whose two people are
# kept as is, tiled into four chunks, and a synthetic athlete with two looks to
# recast them into (db/seeds/data/recast_video.rb). Local only.
return unless Rails.env.local?

require Rails.root.join("db/seeds/data/recast_video.rb").to_s
video = RecastVideo.seed!
safe_puts "  Recast video #{video.slug}: #{video.video_performers.count} performers, #{video.video_chunks.count} chunks, " \
          "athlete #{RecastVideo.athlete!.slug}"
