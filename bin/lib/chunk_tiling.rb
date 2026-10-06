# frozen_string_literal: true

require "tmpdir"
require_relative "digest_video"
require_relative "../../lib/music_videos/chunk_tiler"
require_relative "../../lib/music_videos/clip_cast"
require_relative "../../lib/music_videos/object_keys"

# The Mac side of the recast pipeline's chunks, shared by bin/digest-video
# (which tiles right after it records a source) and bin/find-clips --tile
# (which re-tiles an old one). It cuts the whole video into overlapping chunks
# (MusicVideos::ChunkTiler: 25 s with a 5 s overlap unless told otherwise),
# uploads each to R2 and posts the set to POST /api/v1/music_videos/:slug/clips
# as kind "chunk". ffmpeg only, so it runs where the source MP4 is.
module ChunkTiling
  Failure = DigestVideo::Failure

  # Re-encoded cuts, so the in and out points are exact rather than
  # keyframe-bound. Shared with the seam candidates (bin/find-clips).
  class Cutter
    def initialize(storage:, shell:, out:, bucket:)
      @storage = storage
      @shell = shell
      @out = out
      @bucket = bucket
    end

    def call(mp4, rows)
      Dir.mktmpdir("clips") do |dir|
        rows.each do |r|
          path = File.join(dir, File.basename(r[:object_key]))
          _o, err, ok = @shell.call("ffmpeg", "-y", "-v", "error", "-ss", format("%.3f", r[:start_ms] / 1000.0), "-i", mp4,
                                    "-t", format("%.3f", (r[:end_ms] - r[:start_ms]) / 1000.0), "-map", "0:v:0",
                                    "-map", "0:a:0", "-c:v", "libx264", "-crf", "18", "-preset", "veryfast",
                                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", path)
          raise Failure, "ffmpeg cut failed: #{err.to_s.lines.last&.strip}" unless ok

          @out.puts "uploading r2://#{@bucket}/#{r[:object_key]}"
          @storage.put(r[:object_key], path, "video/mp4")
        end
      end
    end
  end

  # One tiling of one recorded video. replace: false (the digest) leaves a
  # video that already has chunks alone: at the same tiling there is nothing
  # to do, and at another it says how to replace them. replace: true
  # (bin/find-clips --tile, bin/digest-video --retile) always cuts and posts.
  class Runner
    def initialize(api:, storage:, shell:, out: $stdout, dry_run: false, bucket: "mcritchie-studio-dev",
                   chunk_ms: MusicVideos::ChunkTiler::CHUNK_MS, overlap_ms: MusicVideos::ChunkTiler::OVERLAP_MS,
                   replace: false, retile_hint: "--retile")
      @api = api
      @shell = shell
      @out = out
      @dry_run = dry_run
      @tiling = { chunk_ms:, overlap_ms: }
      @replace = replace
      @retile_hint = retile_hint
      @cutter = Cutter.new(storage:, shell:, out:, bucket:)
    end

    # nil when the tiling can cut; else why not. Ask before any download.
    def problem = MusicVideos::ChunkTiler.problem(**@tiling)

    # video: the hub's record as the API serialises it (slug, duration_ms,
    # source_object_key, performers, chunks, chunk_ms, chunk_overlap_ms).
    # Returns the chunk rows posted (or planned, on a dry run); [] when the
    # video's chunks were left as they are.
    def call(video, mp4)
      why = problem
      raise Failure, why if why
      return [] if keep_existing?(video)

      rows = MusicVideos::ChunkTiler.windows(duration(video, mp4), **@tiling).map { |w| row(video, w) }
      report(video, rows)
      return rows if @dry_run

      @cutter.call(mp4, rows)
      @api.post("/api/v1/music_videos/#{video['slug']}/clips",
                { kind: "chunk", chunk_ms: @tiling[:chunk_ms], chunk_overlap_ms: @tiling[:overlap_ms], clips: rows })
      @out.puts "posted #{rows.size} chunks for #{video['slug']}; the clip candidates are untouched"
      rows
    end

    private

    # The re-digest rule: chunks already on the record, cut at this chunk
    # length and overlap, ARE this tiling. The hub accepted them only as the
    # whole tiling of the video (ReplaceClips#check_tiling!), and the source
    # never changes under a recorded video, so cutting again would only
    # re-upload the same files.
    def keep_existing?(video)
      existing = Array(video["chunks"])
      return false if @replace || existing.empty?

      if video["chunk_ms"] == @tiling[:chunk_ms] && video["chunk_overlap_ms"] == @tiling[:overlap_ms]
        @out.puts "#{video['slug']} is already tiled at #{label(@tiling[:chunk_ms], @tiling[:overlap_ms])}: " \
                  "kept its #{existing.size} chunks, cut nothing"
      else
        @out.puts "#{video['slug']} is tiled at #{label(video['chunk_ms'], video['chunk_overlap_ms'])}, not " \
                  "#{label(@tiling[:chunk_ms], @tiling[:overlap_ms])}: kept its #{existing.size} chunks; " \
                  "pass #{@retile_hint} to replace them"
      end
      true
    end

    def label(chunk_ms, overlap_ms) = "#{seconds(chunk_ms.to_i)} s chunks with a #{seconds(overlap_ms.to_i)} s overlap"

    # The file on disk must be the digested video: its length within a second
    # of the recorded one. The tiling ends at the shorter, so no chunk runs
    # past the file or past what the hub knows.
    def duration(video, mp4)
      on_disk = probe(mp4)
      raise Failure, "ffprobe read no duration from #{mp4}" unless on_disk.positive?

      recorded = video["duration_ms"]
      return on_disk unless recorded.is_a?(Integer)

      if (on_disk - recorded).abs > MusicVideos::ChunkTiler::END_TOLERANCE_MS
        raise Failure, "#{File.basename(mp4)} runs #{on_disk} ms but #{video['slug']} is recorded at #{recorded} ms: " \
                       "not the digested source"
      end
      [on_disk, recorded].min
    end

    def probe(mp4)
      out, err, ok = @shell.call("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", mp4)
      raise Failure, "ffprobe failed: #{err.to_s.lines.last&.strip}" unless ok

      (out.to_f * 1000).round
    end

    # Labelled from the cast as it is now. A freshly digested source has none,
    # so its chunks are "unknown" with nobody on screen; the hub relabels them
    # from the cast when the vision pass posts it (MusicVideos::LabelChunks).
    def row(video, window)
      cast = MusicVideos::ClipCast.label(video["performers"] || [], window.start_ms, window.end_ms)
      key = MusicVideos::ObjectKeys.chunk(source_key: video["source_object_key"], ordinal: window.ordinal,
                                          start_ms: window.start_ms, end_ms: window.end_ms)
      { ordinal: window.ordinal, start_ms: window.start_ms, end_ms: window.end_ms, cast_shape: cast.cast_shape,
        target_performer: cast.target, performer_ordinals: cast.present, object_key: key }
    end

    def report(video, rows)
      people = (video["performers"] || []).to_h { |p| [p["ordinal"], p] }
      @out.puts "#{rows.size} chunks for #{video['slug']} (#{seconds(@tiling[:chunk_ms])} s on a " \
                "#{seconds(MusicVideos::ChunkTiler.stride(**@tiling))} s stride)" \
                "#{' (dry run: nothing cut, uploaded or posted)' if @dry_run}"
      rows.each do |r|
        target = people[r[:target_performer]]
        @out.puts format("  %02d  %s-%s  %s  target %s", r[:ordinal], clock(r[:start_ms]), clock(r[:end_ms]), r[:cast_shape],
                         target ? "Person #{target['ordinal']} (#{target['label']})" : "none")
      end
    end

    def seconds(ms) = format("%g", ms / 1000.0)

    def clock(ms) = format("%d:%04.1f", ms / 60_000, (ms % 60_000) / 1000.0)
  end
end
