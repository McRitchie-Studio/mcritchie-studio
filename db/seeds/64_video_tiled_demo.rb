# The chunk list's demo: a synthetic 72 s cinematic video tiled into four
# overlapping chunks beside one clip candidate (db/seeds/data/tiled_video.rb).
# Local only. In development, with ffmpeg and the dev bucket to hand, it also
# builds alt video 1 and renders and uploads playable files and a generated
# version for every clip (db/seeds/data/tiled_video_files.rb), so the players
# and Watch full video load and "Generate full video" has a full set to
# stitch; without them each preview reads "not reachable".
return unless Rails.env.local?

require Rails.root.join("db/seeds/data/tiled_video_files.rb").to_s
video = TiledVideo.seed!
safe_puts "  Tiled video #{video.slug}: #{video.video_chunks.count} chunks, #{video.clip_candidates.count} candidate"
TiledVideoFiles.seed!(video)
