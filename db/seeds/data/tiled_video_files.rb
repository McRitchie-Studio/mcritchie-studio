require "open3"
require "tmpdir"
require_relative "tiled_video"

# Playable files for the tiled demo, so the local page's players, the stitch
# full-video player and the final stitch have something to work on: a 72 s
# test pattern with a beep track as the source, each chunk cut from it, and
# alt video 1 with one generated version for EVERY clip, so it is ready to
# stitch and "Generate full video" works locally. Each version is the same cut
# made to look different (and
# carrying a different tone, so a clip that is not muted is plain to hear), and
# no two neighbours look alike, so a handover and a crossfade are plain to see:
#
#   chunk 1  picture inverted
#   chunk 2  hue turned, and returned smaller (240x136) at 24 fps, the way a
#            generated take comes back at its own size and rate
#   chunk 3  picture inverted
#   chunk 4  greyscale, and half a second short of its window
#
# The pattern carries a running clock, so two takes showing the same clock
# through a crossfade are aligned. Made with ffmpeg on the Mac and uploaded to
# the DEV bucket under the demo's own synthetic keys. Development only;
# skipped, with a line saying why, when ffmpeg or the bucket is missing.
# Idempotent: an object already in the bucket is never replaced.
module TiledVideoFiles
  TAKES = {
    1 => { vf: "negate" },
    2 => { vf: "hue=h=120,scale=240:136,fps=24" },
    3 => { vf: "negate" },
    4 => { vf: "hue=s=0", short_ms: 500 }
  }.freeze

  def self.seed!(video = TiledVideo.seed!, out: $stdout)
    why = blocker
    return out.puts("  Tiled video files skipped: #{why}") if why

    Dir.mktmpdir("tiled-demo") do |dir|
      source = File.join(dir, "source.mp4")
      upload(video.source_object_key) { render_source(source, video.duration_ms) }
      video.video_chunks.each do |chunk|
        upload(chunk.object_key) { cut(source_file(source, video), chunk, File.join(dir, "chunk_#{chunk.ordinal}.mp4")) }
      end
      alt = video.alt_videos.first || AltVideo.build_from!(video)
      alt.clips.each do |clip|
        look = TAKES[clip.chunk_ordinal]
        chunk = clip.chunk_in(video.video_chunks.to_a)
        next unless look && chunk && clip.versions.empty?

        key = MusicVideos::ObjectKeys.alt_clip_version(source_key: video.source_object_key, alt_number: alt.number,
                                                       ordinal: clip.chunk_ordinal, start_ms: clip.start_ms,
                                                       end_ms: clip.end_ms, number: 1)
        path = cut(source_file(source, video), chunk, File.join(dir, "version_#{clip.chunk_ordinal}.mp4"), look:)
        upload(key) { path }
        TiledVideo.version!(clip, number: 1, byte_size: File.size(path))
      end
    end
    versions = AltVideoClipVersion.joins(:clip).where(alt_video_clips: { alt_video_slug: video.alt_videos.select(:slug) }).count
    out.puts "  Tiled video files: source, #{video.video_chunks.count} chunks and #{versions} clip versions in #{Studio::S3.bucket}"
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

  # The local source render, made on first need (a re-run may only owe a version).
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

  # look: a generated version's stand-in, the cut filtered so it is told apart.
  def self.cut(source, chunk, path, look: nil)
    filters = look ? ["-vf", look.fetch(:vf), "-af", "asetrate=44100*2,aresample=44100,atempo=0.5"] : []
    length = chunk.duration_ms - (look && look[:short_ms]).to_i
    ffmpeg("-ss", (chunk.start_ms / 1000.0).to_s, "-t", (length / 1000.0).to_s, "-i", source, *filters,
           "-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-g", "12", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "48k", "-movflags", "+faststart", path)
  end

  def self.ffmpeg(*args, path)
    _out, err, status = Open3.capture3("ffmpeg", "-v", "error", "-y", *args, path)
    raise "ffmpeg failed: #{err.lines.last}" unless status.success?

    path
  end
end
