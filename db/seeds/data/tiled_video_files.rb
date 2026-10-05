require "open3"
require "tmpdir"
require_relative "tiled_video"

# Playable files for the tiled demo, so the local page's players and the stitch
# preview have something to load: a 72 s test pattern with a beep track as the
# source, each chunk cut from it, and a generated take for chunks 1 and 3 (the
# same cut with the picture inverted and a different tone, so a handover is
# plain to see and a clip that is not muted is plain to hear). Chunks 2 and 4
# stay on their source cut. Made with ffmpeg on the Mac and uploaded to the DEV
# bucket under the demo's own synthetic keys. Development only; skipped, with a
# line saying why, when ffmpeg or the bucket is missing. Idempotent.
module TiledVideoFiles
  TAKE_CHUNKS = [1, 3].freeze

  def self.seed!(video = TiledVideo.seed!, out: $stdout)
    why = blocker
    return out.puts("  Tiled video files skipped: #{why}") if why

    Dir.mktmpdir("tiled-demo") do |dir|
      source = File.join(dir, "source.mp4")
      upload(video.source_object_key) { render_source(source, video.duration_ms) }
      video.video_chunks.each do |chunk|
        upload(chunk.object_key) { cut(source_file(source, video), chunk, File.join(dir, "chunk_#{chunk.ordinal}.mp4")) }
        next unless TAKE_CHUNKS.include?(chunk.ordinal) && chunk.takes.empty?

        path = cut(source_file(source, video), chunk, File.join(dir, "take_#{chunk.ordinal}.mp4"), generated: true)
        key = MusicVideos::ObjectKeys.take(source_key: video.source_object_key, ordinal: chunk.ordinal,
                                           start_ms: chunk.start_ms, end_ms: chunk.end_ms, number: 1)
        File.open(path, "rb") { |io| Studio::S3.upload(key:, body: io, content_type: "video/mp4") }
        TiledVideo.take!(chunk, number: 1, byte_size: File.size(path))
      end
    end
    out.puts "  Tiled video files: source, #{video.video_chunks.count} chunks and #{video.chunk_takes.count} takes in #{Studio::S3.bucket}"
  rescue StandardError => e
    out.puts "  Tiled video files skipped: #{e.class.name.demodulize}"
  end

  def self.blocker
    return "development only" unless Rails.env.development?
    return "ffmpeg is not installed" unless system("command -v ffmpeg > /dev/null 2>&1")

    "object storage is not configured" unless Studio::S3.configured?
  end

  # Upload the file the block renders, unless the object is already there.
  def self.upload(key)
    return if Studio::S3.exists?(key:)

    File.open(yield, "rb") { |io| Studio::S3.upload(key:, body: io, content_type: "video/mp4") }
  end

  # The local source render, made on first need (a re-run may only owe a take).
  def self.source_file(path, video)
    File.exist?(path) ? path : render_source(path, video.duration_ms)
  end

  def self.render_source(path, duration_ms)
    seconds = duration_ms / 1000.0
    ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=#{seconds}",
           "-f", "lavfi", "-i", "sine=frequency=330:beep_factor=4:duration=#{seconds}",
           "-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-g", "12", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "48k", "-movflags", "+faststart", "-shortest", path)
  end

  def self.cut(source, chunk, path, generated: false)
    filters = generated ? ["-vf", "negate", "-af", "asetrate=44100*2,aresample=44100,atempo=0.5"] : []
    ffmpeg("-ss", (chunk.start_ms / 1000.0).to_s, "-t", (chunk.duration_ms / 1000.0).to_s, "-i", source, *filters,
           "-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-g", "12", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "48k", "-movflags", "+faststart", path)
  end

  def self.ffmpeg(*args, path)
    _out, err, status = Open3.capture3("ffmpeg", "-v", "error", "-y", *args, path)
    raise "ffmpeg failed: #{err.lines.last}" unless status.success?

    path
  end
end
