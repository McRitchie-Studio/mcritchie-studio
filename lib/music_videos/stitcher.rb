# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module MusicVideos
  # Runs one stitch: fetch the takes and the source, probe them, plan
  # (MusicVideos::StitchPlan), run ffmpeg, check the result against the plan,
  # store it. The one code path for the stitch, on the Mac (bin/stitch-video)
  # and in a hub that has ffmpeg (StitchVideoJob). It knows no Rails and no
  # API: the caller hands it the request, a store and a working folder. Outside
  # Rails, require stitch_plan.rb first (bin/lib/stitch_video.rb does).
  #
  # request (string keys, as the API serves it):
  #   "object_key"         where the stitched MP4 goes
  #   "source_object_key"  the source MP4, for its audio and its frame
  #   "takes"              [{ "ordinal", "start_ms", "end_ms", "take", "object_key" }] in order
  #
  # store answers get(key, path) and put(key, path, content_type).
  class Stitcher
    class Failure < StandardError; end

    TOOLS = %w[ffmpeg ffprobe].freeze
    # Above this a nominal rate is a timebase artefact (90000/1), not a rate.
    MAX_NOMINAL_RATE = 120
    PROBE = %w[ffprobe -v error -show_entries
               stream=codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,nb_frames,duration:format=duration
               -of json].freeze

    Result = Data.define(:path, :plan, :duration_ms, :audio_ms, :frames, :width, :height, :frame_rate, :video_codec,
                         :audio_codec, :byte_size, :warnings) do
      # What a finished stitch reports (the API's finish body, the record's columns).
      def report
        { "duration_ms" => duration_ms, "byte_size" => byte_size, "width" => width, "height" => height,
          "frame_rate" => frame_rate, "warnings" => warnings }
      end
    end

    # Whether this machine can stitch: ffmpeg and ffprobe on PATH. Production
    # dynos have neither, so there a request waits for bin/stitch-video.
    def self.available?(path: ENV["PATH"].to_s)
      dirs = path.split(File::PATH_SEPARATOR).reject(&:empty?)
      TOOLS.all? { |tool| dirs.any? { |dir| File.executable?(File.join(dir, tool)) && !File.directory?(File.join(dir, tool)) } }
    end

    def self.shell
      lambda do |*cmd|
        out, err, status = Open3.capture3(*cmd)
        [out, err, status.success?]
      rescue Errno::ENOENT
        raise Failure, "#{File.basename(cmd.first)} not found"
      end
    end

    def initialize(shell: self.class.shell, out: $stdout)
      @shell = shell
      @out = out
    end

    # Fetch, stitch, check, store. source: a source MP4 already on disk.
    # dry_run: stop after the plan; nothing is encoded or stored.
    def call(request, store:, dir:, source: nil, dry_run: false)
      plan = plan(request, store:, dir:, source:)
      describe(plan)
      return plan if dry_run

      result = encode(plan, request.fetch("takes").size)
      @out.puts "storing #{request.fetch('object_key')}"
      store.put(request.fetch("object_key"), result.path, "video/mp4")
      result
    end

    # The plan for a request, with every input fetched and measured.
    def plan(request, store:, dir:, source: nil)
      rows = request.fetch("takes")
      raise Failure, "the request names no takes" if rows.empty?

      FileUtils.mkdir_p(dir)
      source_path = source || fetch(store, request.fetch("source_object_key"), dir)
      measured = probe(source_path)
      raise Failure, "#{File.basename(source_path)} has no picture" unless measured[:width]

      takes = rows.map do |row|
        seen = probe(fetch(store, row.fetch("object_key"), dir))
        raise Failure, "chunk #{row['ordinal']}'s take has no picture: #{File.basename(seen[:path])}" unless seen[:width]

        StitchPlan::Take.new(ordinal: row.fetch("ordinal"), start_ms: row.fetch("start_ms"), end_ms: row.fetch("end_ms"),
                             **seen.slice(:path, :width, :height, :frame_rate, :duration_ms))
      end
      StitchPlan.build(takes:, source: StitchPlan::Source.new(**measured.slice(:path, :width, :height, :frame_rate, :audio_codec)),
                       output: File.join(dir, File.basename(request.fetch("object_key"))))
    rescue StitchPlan::Invalid => e
      raise Failure, e.message
    end

    # Run the plan's ffmpeg and hold the file to it: the picture must be the
    # planned length within one frame per chunk, or the stitch is not stored.
    def encode(plan, chunks)
      output = plan.arguments.last
      _out, err, ok = @shell.call("ffmpeg", *plan.arguments)
      raise Failure, "ffmpeg failed: #{err.to_s.lines.last&.strip}" unless ok

      seen = probe(output)
      frames = seen[:frames] || StitchPlan.frame(seen[:video_ms], plan.target.frame_rate)
      unless (frames - plan.total_frames).abs <= chunks
        raise Failure, "the stitch came out #{frames} frames long, not the planned #{plan.total_frames} (over one frame per chunk)"
      end

      Result.new(path: output, plan:, duration_ms: seen[:duration_ms], audio_ms: seen[:audio_ms], frames:,
                 width: seen[:width], height: seen[:height], frame_rate: plan.target.rate_label,
                 video_codec: seen[:video_codec], audio_codec: seen[:audio_codec], byte_size: File.size(output),
                 warnings: plan.warnings)
    end

    # ffprobe's measurements of one MP4. Missing streams read as nil.
    def probe(path)
      out, err, ok = @shell.call(*PROBE, path)
      raise Failure, "ffprobe could not read #{File.basename(path)}: #{err.to_s.lines.last&.strip}" unless ok

      data = JSON.parse(out)
      video = data["streams"].find { |s| s["codec_type"] == "video" }
      audio = data["streams"].find { |s| s["codec_type"] == "audio" }
      { path:, width: video&.dig("width"), height: video&.dig("height"), frame_rate: video && rate(video),
        frames: video && video["nb_frames"].to_i.then { |n| n.positive? ? n : nil },
        video_codec: video&.dig("codec_name"), audio_codec: audio&.dig("codec_name"),
        video_ms: millis(video&.dig("duration")), audio_ms: millis(audio&.dig("duration")),
        duration_ms: millis(video&.dig("duration")) || millis(data.dig("format", "duration")) }
    rescue JSON::ParserError
      raise Failure, "ffprobe answered no JSON for #{File.basename(path)}"
    end

    private

    def fetch(store, key, dir)
      path = File.join(dir, File.basename(key))
      return path if File.size?(path)

      # Fetched under another name and renamed whole, so a download cut short
      # is never mistaken for the file on the next run.
      @out.puts "fetching #{key}"
      partial = "#{path}.part"
      store.get(key, partial)
      raise Failure, "#{key} came back empty" unless File.size?(partial)

      File.rename(partial, path)
      path
    end

    # The nominal rate when it is a real one and the file keeps to it (a
    # constant-rate file states it exactly: 24/1, 24000/1001); else the
    # average, which is what a variable-rate file actually delivers.
    def rate(stream)
      nominal, average = [stream["r_frame_rate"], stream["avg_frame_rate"]].map do |text|
        num, den = text.to_s.split("/").map(&:to_i)
        Rational(num, den) if num.to_i.positive? && den.to_i.positive?
      end
      raise Failure, "ffprobe read no frame rate" unless nominal || average
      return average unless nominal && nominal <= MAX_NOMINAL_RATE
      return nominal unless average

      ((average - nominal) / nominal).abs <= Rational(1, 20) ? nominal : average
    end

    def millis(seconds)
      value = Float(seconds, exception: false)
      value && (value * 1000).round
    end

    def describe(plan)
      t = plan.target
      @out.puts "stitch plan: #{plan.inputs.size} takes -> #{t.width}x#{t.height} at #{t.rate_label} fps, " \
                "#{plan.total_frames} frames (#{format('%.3f', plan.duration_ms / 1000.0)} s), audio #{plan.audio}"
      plan.inputs.each_with_index do |i, n|
        join = n.zero? ? nil : plan.joins[n - 1]
        how = if join.nil? then "opens the video"
              elsif join.cut? then "cuts in at frame #{join.offset_frame}"
              else "fades in over #{join.frames} frames from frame #{join.offset_frame}"
              end
        @out.puts format("  chunk %02d  frames %d-%d  %s  %s", i.ordinal, i.start_frame, i.end_frame, i.fit, how)
      end
      plan.warnings.each { |w| @out.puts "  note: #{w}" }
    end
  end
end
