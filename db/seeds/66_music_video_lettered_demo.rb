# The lettered clip references' demo (recast pipeline, piece 16): a synthetic
# cinematic video with three people, two swapped in alt video 1 into looks
# with jersey numbers, and chunk 3 carrying lettered reference frames
# (db/seeds/data/lettered_video.rb). Local only. In development, with ffmpeg
# and the dev bucket, it also renders the source and its chunks
# (db/seeds/data/lettered_video_files.rb), so bin/clip-references has a real
# source to still.
return unless Rails.env.local?

require Rails.root.join("db/seeds/data/lettered_video_files.rb").to_s
video = LetteredVideo.seed!
safe_puts "  Lettered video #{video.slug}: #{video.video_performers.count} people, #{video.video_chunks.count} chunks, " \
          "alt video #{video.alt_videos.first&.number}"
LetteredVideoFiles.seed!(video)
