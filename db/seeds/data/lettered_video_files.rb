require_relative "tiled_video_files"
require_relative "lettered_video"

# Playable files for the lettered demo, so bin/clip-references has a real
# source to still and the clip cards a chunk to preview: a 72 s picture of
# three standing figures (Person A, a red coat on the left throughout; Person
# B, a blue dress in the middle 0:40-1:05; Person C, a small green figure at
# the back 0:45-1:00) over a beep track, and each chunk cut from it. Made with
# ffmpeg on the Mac and uploaded to the DEV bucket under the demo's synthetic
# keys. Development only; skipped with a line saying why, like TiledVideoFiles.
# The lettered frames themselves are made by running bin/clip-references.
module LetteredVideoFiles
  FIGURES = [
    "drawbox=x=80:y=120:w=70:h=200:color=0xc0392b:t=fill", "drawbox=x=93:y=78:w=44:h=40:color=0xe8c39e:t=fill",
    "drawbox=x=280:y=110:w=80:h=220:color=0x2e64c8:t=fill:enable='between(t,40,65)'",
    "drawbox=x=298:y=64:w=44:h=42:color=0xd9a77c:t=fill:enable='between(t,40,65)'",
    "drawbox=x=492:y=120:w=40:h=130:color=0x27ae60:t=fill:enable='between(t,45,60)'",
    "drawbox=x=497:y=92:w=30:h=26:color=0xc69c6d:t=fill:enable='between(t,45,60)'"
  ].freeze

  def self.seed!(video = LetteredVideo.seed!, out: $stdout)
    why = TiledVideoFiles.blocker
    return out.puts("  Lettered video files skipped: #{why}") if why

    Dir.mktmpdir("lettered-demo") do |dir|
      source = File.join(dir, "source.mp4")
      TiledVideoFiles.upload(video.source_object_key) { render_source(source, video.duration_ms) }
      video.video_chunks.each do |chunk|
        TiledVideoFiles.upload(chunk.object_key) do
          TiledVideoFiles.cut(File.exist?(source) ? source : render_source(source, video.duration_ms), chunk,
                              File.join(dir, "chunk_#{chunk.ordinal}.mp4"))
        end
      end
    end
    out.puts "  Lettered video files: source and #{video.video_chunks.count} chunks in #{Studio::S3.bucket}"
  rescue StandardError => e
    out.puts "  Lettered video files skipped: #{e.class.name.demodulize}"
  end

  def self.render_source(path, duration_ms)
    seconds = duration_ms / 1000.0
    TiledVideoFiles.ffmpeg("-f", "lavfi", "-i", "color=c=0x1d2433:size=640x360:rate=12:duration=#{seconds}",
                           "-f", "lavfi", "-i", "sine=frequency=330:beep_factor=4:duration=#{seconds}",
                           "-vf", FIGURES.join(","), "-c:v", "libx264", "-preset", "veryfast", "-crf", "28", "-g", "12",
                           "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "48k", "-movflags", "+faststart", "-shortest", path)
  end
end
