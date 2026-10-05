# frozen_string_literal: true

module MusicVideos
  # The final stitch, planned: which files go in, what each is normalised to,
  # where each crossfade starts and how long it runs, the filter graph and the
  # ffmpeg arguments. Pure Ruby: it runs nothing and reads no file. The caller
  # (MusicVideos::Stitcher) probes the files and hands the measurements in.
  #
  # PICTURE. Take N crossfades into take N+1 across the overlap their windows
  # share (ffmpeg xfade). Everything is timed from each chunk's recorded window
  # (start_ms, end_ms) and counted in output frames, never from a file's
  # length: chunk N owns frames round(start * rate)...round(end * rate), so a
  # rounding error never accumulates down the chain and the whole video is
  # round(last end * rate) frames. A take that runs short of its window holds
  # its last frame; one that runs long is trimmed.
  #
  # NORMALISATION. Generated takes come back at their own sizes and rates, and
  # xfade needs every input alike. The target is the best any take offers and
  # never more than the source: the largest take's frame (the source's frame if
  # a take exceeds it), and the highest take frame rate capped at the source's.
  # So a set of takes that all came back smaller than the source is stitched at
  # their size, with no invented pixels; a mixed set is brought up to its best
  # member; nothing is ever scaled past the source. Pixel format yuv420p,
  # square pixels.
  #
  # AUDIO. The source's own audio, whole, mapped straight to the output. It
  # passes through no filter, so the fades cannot touch it; an AAC track is
  # copied bit for bit. The takes' audio is never read.
  module StitchPlan
    class Invalid < ArgumentError; end

    # A take whose shape is this close to the target's is stretched to it
    # (under 2 %, invisible); past that it is fitted inside and padded black.
    STRETCH_TOLERANCE = 0.02
    # A take this far off its window is worth a line to the operator.
    DRIFT_FRAMES = 2
    # Rates a probe may report a hair off (a 29.97 file averaging 2997/100).
    RATE_TOLERANCE = Rational(1, 4000)
    STANDARD_RATES = [Rational(24_000, 1001), 24, 25, Rational(30_000, 1001), 30, 48, 50,
                      Rational(60_000, 1001), 60].map { |r| Rational(r) }.freeze
    VIDEO_CODEC = %w[-c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p].freeze
    AUDIO_ENCODE = %w[-c:a aac -b:a 192k].freeze

    # What the caller measured. frame_rate is a Rational; duration_ms the
    # file's own length (used only to tell the operator about drift).
    Take = Data.define(:ordinal, :start_ms, :end_ms, :path, :width, :height, :frame_rate, :duration_ms)
    # audio_codec is nil for a source with no audio stream.
    Source = Data.define(:path, :width, :height, :frame_rate, :audio_codec)

    Target = Data.define(:width, :height, :frame_rate) do
      def rate_label = frame_rate.denominator == 1 ? frame_rate.numerator.to_s : "#{frame_rate.numerator}/#{frame_rate.denominator}"
    end
    # One take on the output's frame clock. fit: :exact, :stretch or :pad.
    # adjust_ms: how far the file runs past (+, trimmed) or short of (-, held)
    # its window.
    Input = Data.define(:index, :ordinal, :path, :start_frame, :end_frame, :fit, :adjust_ms) do
      def frames = end_frame - start_frame
    end
    # Where take `ordinal` joins the picture so far: a crossfade of `frames`
    # starting at output frame `offset_frame`, or a plain cut when frames is 0.
    Join = Data.define(:ordinal, :offset_frame, :frames) do
      def cut? = frames.zero?
    end
    Plan = Data.define(:target, :inputs, :joins, :total_frames, :duration_ms, :audio, :filter_graph, :arguments, :warnings)

    module_function

    # takes in time order, the source, and where to write -> a Plan.
    def build(takes:, source:, output:)
      takes = takes.to_a
      check!(takes)
      target = target_for(takes, source)
      inputs = takes.each_with_index.map { |take, i| input(take, i, target) }
      joins = inputs.each_cons(2).map { |left, right| join(left, right) }
      total = inputs.last.end_frame
      audio = audio_for(source)
      graph = filter_graph(inputs, joins, target)
      Plan.new(target:, inputs:, joins:, total_frames: total, duration_ms: ms(total, target.frame_rate), audio:,
               filter_graph: graph,
               arguments: arguments(inputs, source, graph, audio, seconds(total, target.frame_rate), output),
               warnings: warnings(takes, inputs, target, source))
    end

    # The best any take offers, never more than the source.
    def target_for(takes, source)
      best = takes.max_by { |t| [t.width * t.height, t.width] }
      width, height = best.width, best.height
      width, height = source.width, source.height if width > source.width || height > source.height
      rate = [takes.map { |t| standard(t.frame_rate) }.max, standard(source.frame_rate)].min
      Target.new(width: width - (width % 2), height: height - (height % 2), frame_rate: rate)
    end

    # A probed rate a hair off a standard one is that standard rate. The
    # tolerance sits well inside the 0.1 % between 24 and 23.976.
    def standard(rate)
      rate = Rational(rate)
      raise Invalid, "a frame rate above zero is required" unless rate.positive?

      nearest = STANDARD_RATES.min_by { |s| (rate - s).abs }
      ((rate - nearest) / nearest).abs <= RATE_TOLERANCE ? nearest : rate
    end

    # The output frame the video clock t_ms falls on.
    def frame(t_ms, rate) = (Rational(t_ms, 1000) * rate).round

    def seconds(frames, rate) = format("%.6f", (Rational(frames) / rate).to_f)

    def ms(frames, rate) = (Rational(frames * 1000) / rate).round

    def check!(takes)
      raise Invalid, "a stitch needs at least one take" if takes.empty?
      raise Invalid, "the first chunk must start at 0, not #{takes.first.start_ms} ms" unless takes.first.start_ms.zero?

      takes.each do |t|
        raise Invalid, "chunk #{t.ordinal} has no length" unless t.end_ms > t.start_ms
        raise Invalid, "chunk #{t.ordinal}'s take has no picture size" unless t.width.to_i.positive? && t.height.to_i.positive?
      end
      takes.each_cons(2) do |left, right|
        unless right.start_ms > left.start_ms && right.end_ms > left.end_ms
          raise Invalid, "chunk #{right.ordinal} does not run on from chunk #{left.ordinal}"
        end
        next if right.start_ms <= left.end_ms

        raise Invalid, "chunk #{right.ordinal} starts #{right.start_ms - left.end_ms} ms after chunk #{left.ordinal} ends: " \
                       "the tiling has a hole"
      end
    end

    def input(take, index, target)
      rate = target.frame_rate
      Input.new(index:, ordinal: take.ordinal, path: take.path, start_frame: frame(take.start_ms, rate),
                end_frame: frame(take.end_ms, rate), fit: fit(take, target),
                adjust_ms: take.duration_ms.to_i - (take.end_ms - take.start_ms))
    end

    def fit(take, target)
      return :exact if take.width == target.width && take.height == target.height

      shape = Rational(take.width, take.height)
      wanted = Rational(target.width, target.height)
      ((shape - wanted) / wanted).abs <= STRETCH_TOLERANCE ? :stretch : :pad
    end

    # The overlap, in frames: from where the right take starts to where the
    # left one ends. Both are that window's own rounded frame, so the fade
    # covers exactly the frames the two share.
    def join(left, right)
      Join.new(ordinal: right.ordinal, offset_frame: right.start_frame, frames: [left.end_frame - right.start_frame, 0].max)
    end

    def audio_for(source)
      return :none if source.audio_codec.to_s.empty?

      source.audio_codec == "aac" ? :copy : :encode
    end

    # One chain per take (normalise, then hold or trim to its window's frame
    # count), then the takes joined left to right. Each join's offset is the
    # right take's absolute start, so the chain cannot drift.
    def filter_graph(inputs, joins, target)
      rate = target.frame_rate
      chains = inputs.map do |i|
        "[#{i.index}:v:0]setpts=PTS-STARTPTS,fps=#{target.rate_label},#{scale(i.fit, target)}setsar=1,format=yuv420p," \
          "tpad=stop_mode=clone:stop_duration=#{seconds(i.frames, rate)},trim=end_frame=#{i.frames},setpts=PTS-STARTPTS[v#{i.index}]"
      end
      last = "v0"
      links = joins.each_with_index.map do |j, n|
        from = last
        last = n == joins.size - 1 ? "vout" : "x#{n + 1}"
        if j.cut?
          "[#{from}][v#{n + 1}]concat=n=2:v=1:a=0[#{last}]"
        else
          "[#{from}][v#{n + 1}]xfade=transition=fade:duration=#{seconds(j.frames, rate)}:offset=#{seconds(j.offset_frame, rate)}[#{last}]"
        end
      end
      links << "[v0]null[vout]" if joins.empty?
      (chains + links).join(";")
    end

    def scale(fit, target)
      size = "#{target.width}:#{target.height}"
      case fit
      when :exact then ""
      when :stretch then "scale=#{size}:flags=lanczos,"
      else "scale=#{size}:force_original_aspect_ratio=decrease:flags=lanczos,pad=#{size}:(ow-iw)/2:(oh-ih)/2:black,"
      end
    end

    # Everything after `ffmpeg`. The takes come first, picture only; the
    # source last, audio only.
    def arguments(inputs, source, graph, audio, length, output)
      args = %w[-y -v error -nostdin]
      inputs.each { |i| args.push("-an", "-i", i.path) }
      args.push("-vn", "-i", source.path) unless audio == :none
      args.push("-filter_complex", graph, "-map", "[vout]")
      args.push("-map", "#{inputs.size}:a:0") unless audio == :none
      args.concat(VIDEO_CODEC)
      args.concat(audio == :copy ? %w[-c:a copy] : AUDIO_ENCODE) unless audio == :none
      args.push("-t", length, "-movflags", "+faststart", output)
    end

    def warnings(takes, inputs, target, source)
      frame_ms = (Rational(1000) / target.frame_rate).to_f
      list = takes.zip(inputs).filter_map do |take, i|
        next if take.duration_ms.nil? || i.adjust_ms.abs <= DRIFT_FRAMES * frame_ms

        window = format("%.1f", (take.end_ms - take.start_ms) / 1000.0)
        ran = format("%.1f", take.duration_ms / 1000.0)
        fix = i.adjust_ms.negative? ? "its last frame is held for #{-i.adjust_ms} ms" : "its last #{i.adjust_ms} ms are trimmed"
        "chunk #{take.ordinal}'s take runs #{ran} s for a #{window} s window: #{fix}"
      end
      padded = inputs.select { |i| i.fit == :pad }.map(&:ordinal)
      list << "chunk #{padded.join(', ')}: the take's shape differs from #{target.width}x#{target.height}, so it is padded black" if padded.any?
      list << "the source has no audio: the stitch is silent" if source.audio_codec.to_s.empty?
      list
    end
  end
end
