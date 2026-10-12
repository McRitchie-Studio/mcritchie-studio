# The recast picker's demo: a synthetic cinematic video whose two people are
# kept as is, tiled into four chunks, and a synthetic athlete with two looks to
# recast them into (db/seeds/data/recast_video.rb). Local only.
return unless Rails.env.local?

require Rails.root.join("db/seeds/data/recast_video.rb").to_s
video = RecastVideo.seed!
safe_puts "  Recast video #{video.slug}: #{video.video_performers.count} performers, #{video.video_chunks.count} chunks, " \
          "athlete #{RecastVideo.athlete!.slug}"

# And an open card for the search rows: one unanswered person, and a synthetic
# athlete with a team and no look yet (db/seeds/data/search_rows_video.rb).
require Rails.root.join("db/seeds/data/search_rows_video.rb").to_s
open_video = SearchRowsVideo.seed!
safe_puts "  Search rows video #{open_video.slug}: look-less athlete #{SearchRowsVideo.rookie!.slug}"
