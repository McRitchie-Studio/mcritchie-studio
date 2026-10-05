# The chunk list's demo: a synthetic 72 s cinematic video tiled into four
# overlapping chunks beside one clip candidate (db/seeds/data/tiled_video.rb).
# Local only. In development, with ffmpeg and the dev bucket to hand, it also
# renders and uploads playable files and a generated take for every chunk
# (db/seeds/data/tiled_video_files.rb), so the players and the stitch preview
# load and "Generate full video" has a full set to stitch; without them each
# preview reads "not reachable" and the video is not ready to stitch.
return unless Rails.env.local?

require Rails.root.join("db/seeds/data/tiled_video_files.rb").to_s
video = TiledVideo.seed!
safe_puts "  Tiled video #{video.slug}: #{video.video_chunks.count} chunks, #{video.clip_candidates.count} candidate"
TiledVideoFiles.seed!(video)
