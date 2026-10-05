# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require_relative "digest_video"
require_relative "../../lib/music_videos/chunk_tiler"
require_relative "../../lib/music_videos/clip_cast"
require_relative "../../lib/music_videos/clip_finder"
require_relative "../../lib/music_videos/clip_prompt"
require_relative "../../lib/music_videos/object_keys"

# The agent side of stage 5, clips (bin/find-clips): measure the source's
# audio with ffmpeg, pick 25 s windows at seams, cut each to H.264/AAC, upload
# to R2 and post the set to POST /api/v1/music_videos/:slug/clips. ffmpeg only;
# no Python packages. Runs where the source MP4 is (the operator's Mac).
#
# With tile: true (bin/find-clips --tile) it measures only the duration and
# cuts the whole video into overlapping chunks (MusicVideos::ChunkTiler): 25 s
# with a 5 s overlap unless chunk_ms and overlap_ms say otherwise. They are
# posted as kind "chunk". The seam candidates and the chunks never replace each other.
module FindClips
  Failure = DigestVideo::Failure
  READY = %w[cast_confirmed clips_ready].freeze
  BAND_FILTERS = { "low" => "lowpass=f=150", "mid" => "highpass=f=300,lowpass=f=3000",
                   "high" => "highpass=f=5000", "full" => "anull" }.freeze
  SCENE = 0.3

  # ffmpeg measurements of one MP4.
  class Audio
    def initialize(shell)
      @shell = shell
    end

    # Per-band RMS level in dB, one value per 0.5 s frame (8 000 samples at 16 kHz).
    def bands(mp4)
      Dir.mktmpdir("find-clips") do |dir|
        stats = "asetnsamples=n=8000:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level"
        names = BAND_FILTERS.keys
        chains = names.map { |n| "[#{n}]#{BAND_FILTERS[n]},#{stats}:file=#{File.join(dir, "#{n}.txt")}[o#{n}]" }
        graph = "[0:a]aresample=16000,pan=mono|c0=0.5*c0+0.5*c1,asplit=#{names.size}#{names.map { |n| "[#{n}]" }.join};" +
                chains.join(";")
        outputs = names.flat_map { |n| ["-map", "[o#{n}]", "-f", "null", "-"] }
        run("ffmpeg", "-v", "error", "-i", mp4, "-vn", "-filter_complex", graph, *outputs)
        names.to_h { |n| [n, levels(File.read(File.join(dir, "#{n}.txt")))] }
      end
    end

    # [[start_ms, end_ms]] quieter than -40 dB for half a second or more.
    def silences(mp4)
      err = run("ffmpeg", "-v", "info", "-i", mp4, "-vn", "-af", "silencedetect=noise=-40dB:d=0.5", "-f", "null", "-")
      FindClips.silences(err)
    end

    # Scene cuts in ms, from the decoder's own timestamps (not the fps filter).
    def cuts(mp4)
      err = run("ffmpeg", "-v", "info", "-i", mp4, "-an", "-vf", "scale=160:-2,select='gt(scene,#{SCENE})',showinfo",
                "-f", "null", "-")
      err.scan(/Parsed_showinfo.*?pts_time:([\d.]+)/).flatten.map { |s| (s.to_f * 1000).round }
    end

    def duration_ms(mp4)
      out = run_out("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", mp4)
      (out.to_f * 1000).round
    end

    def levels(text)
      text.scan(/RMS_level=(\S+)/).flatten.map { |v| v == "-inf" ? -99.0 : [v.to_f, -99.0].max }
    end

    private

    def run(*cmd)
      _out, err, ok = @shell.call(*cmd)
      raise Failure, "#{cmd.first} failed: #{err.to_s.lines.last&.strip}" unless ok

      err
    end

    def run_out(*cmd)
      out, err, ok = @shell.call(*cmd)
      raise Failure, "#{cmd.first} failed: #{err.to_s.lines.last&.strip}" unless ok

      out
    end
  end

  def self.silences(stderr)
    starts = stderr.scan(/silence_start: ([\d.]+)/).flatten.map { |s| (s.to_f * 1000).round }
    ends = stderr.scan(/silence_end: ([\d.]+)/).flatten.map { |s| (s.to_f * 1000).round }
    starts.each_with_index.map { |s, i| [s, ends[i] || Float::INFINITY] }
  end

  # One run: fetch the video and cast, find windows, cut, upload, post.
  class Runner
    def initialize(api:, storage:, shell:, out: $stdout, workdir:, source: nil, dry_run: false, count: 5,
                   bucket: "mcritchie-studio-dev", tile: false, chunk_ms: MusicVideos::ChunkTiler::CHUNK_MS,
                   overlap_ms: MusicVideos::ChunkTiler::OVERLAP_MS)
      @api = api
      @storage = storage
      @shell = shell
      @audio = Audio.new(shell)
      @out = out
      @workdir = workdir
      @source = source
      @dry_run = dry_run
      @count = count
      @bucket = bucket
      @tile = tile
      @tiling = { chunk_ms:, overlap_ms: }
    end

    def call(slug)
      why = @tile && MusicVideos::ChunkTiler.problem(**@tiling)
      raise Failure, why if why

      video = @api.show(slug)
      unless READY.include?(video["stage"])
        raise Failure, "#{slug} is #{video['stage']}: confirm the cast on /music_videos/#{slug} first"
      end

      mp4 = source_mp4(video)
      return tile(video, mp4) if @tile

      proposals = find(video, mp4)
      raise Failure, "no window of continuous music spans a seam in #{slug}" if proposals.empty?

      rows = proposals.map { |p| row(video, p) }
      report(video, rows)
      return rows if @dry_run

      cut_and_upload(mp4, rows)
      data = @api.post("/api/v1/music_videos/#{slug}/clips", { clips: rows })
      @out.puts "posted #{rows.size} clips; #{slug} is #{data['stage']}"
      rows
    end

    private

    # --tile: the whole video as overlapping chunks, replacing only the chunks.
    def tile(video, mp4)
      rows = MusicVideos::ChunkTiler.windows(tiling_duration(video, mp4), **@tiling).map { |w| chunk_row(video, w) }
      report_chunks(video, rows)
      return rows if @dry_run

      cut_and_upload(mp4, rows)
      @api.post("/api/v1/music_videos/#{video['slug']}/clips",
                { kind: "chunk", chunk_ms: @tiling[:chunk_ms], chunk_overlap_ms: @tiling[:overlap_ms], clips: rows })
      @out.puts "posted #{rows.size} chunks for #{video['slug']}; the clip candidates are untouched"
      rows
    end

    # The file on disk must be the digested video: its length within a second
    # of the recorded one. The tiling ends at the shorter, so no chunk runs
    # past the file or past what the hub knows.
    def tiling_duration(video, mp4)
      on_disk = @audio.duration_ms(mp4)
      raise Failure, "ffprobe read no duration from #{mp4}" unless on_disk.positive?

      recorded = video["duration_ms"]
      return on_disk unless recorded.is_a?(Integer)

      if (on_disk - recorded).abs > MusicVideos::ChunkTiler::END_TOLERANCE_MS
        raise Failure, "#{File.basename(mp4)} runs #{on_disk} ms but #{video['slug']} is recorded at #{recorded} ms: " \
                       "not the digested source"
      end
      [on_disk, recorded].min
    end

    def chunk_row(video, window)
      cast = MusicVideos::ClipCast.label(video["performers"] || [], window.start_ms, window.end_ms)
      key = MusicVideos::ObjectKeys.chunk(source_key: video["source_object_key"], ordinal: window.ordinal,
                                          start_ms: window.start_ms, end_ms: window.end_ms)
      { ordinal: window.ordinal, start_ms: window.start_ms, end_ms: window.end_ms, cast_shape: cast.cast_shape,
        target_performer: cast.target, performer_ordinals: cast.present, object_key: key }
    end

    def find(video, mp4)
      MusicVideos::ClipFinder.new(
        bands: @audio.bands(mp4), silences: @audio.silences(mp4), cuts: @audio.cuts(mp4),
        sections: video.dig("caption_timing", "sections") || [], performers: video["performers"] || [],
        count: @count
      ).proposals
    end

    def row(video, proposal)
      key = MusicVideos::ObjectKeys.clip(source_key: video["source_object_key"], ordinal: proposal.ordinal,
                                         seam: proposal.seam, cast_shape: proposal.cast_shape,
                                         start_ms: proposal.start_ms, end_ms: proposal.end_ms)
      { ordinal: proposal.ordinal, start_ms: proposal.start_ms, end_ms: proposal.end_ms, seam: proposal.seam,
        seam_ms: proposal.seam_ms, cast_shape: proposal.cast_shape, target_performer: proposal.target_performer,
        performer_ordinals: proposal.performer_ordinals, object_key: key }
    end

    # --source, else the digest's working folder, else the stored source from R2.
    def source_mp4(video)
      return @source if @source

      dir = File.join(@workdir, video["source_id"])
      local = Dir.glob(File.join(dir, "*#{video['source_id']}*.mp4")).max_by { |p| p.end_with?(".h264.mp4") ? 1 : 0 }
      return local if local

      FileUtils.mkdir_p(dir)
      path = File.join(dir, File.basename(video["source_object_key"]))
      @out.puts "downloading r2://#{@bucket}/#{video['source_object_key']}"
      @storage.get(video["source_object_key"], path)
    end

    # Re-encoded, so the in and out points are exact rather than keyframe-bound.
    def cut_and_upload(mp4, rows)
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

    def report(video, rows)
      people = (video["performers"] || []).to_h { |p| [p["ordinal"], p] }
      @out.puts "#{rows.size} clips for #{video['slug']}#{' (dry run: nothing cut, uploaded or posted)' if @dry_run}"
      rows.each do |r|
        target = people[r[:target_performer]]
        @out.puts format("  %02d  %s-%s  seam %s at %s  %s  target %s", r[:ordinal], clock(r[:start_ms]), clock(r[:end_ms]),
                         r[:seam], clock(r[:seam_ms]), r[:cast_shape],
                         target ? "Person #{target['ordinal']} (#{target['label']})" : "none")
      end
    end

    def report_chunks(video, rows)
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
