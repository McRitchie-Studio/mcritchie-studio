# frozen_string_literal: true

require_relative "clip_cast"

module MusicVideos
  # Picks ~25 s clip windows from a music video's audio structure and its
  # confirmed cast. Pure Ruby: bin/find-clips measures the audio with ffmpeg
  # and hands the numbers in. Each window starts on a musical boundary, spans a
  # seam, and lies inside continuous music (no intro, outro or silence).
  #
  # Boundaries are energy steps in three bands (bass, mids, highs): the mean
  # level over the next 8 s against the previous 8 s. A rise reads as verse to
  # chorus and a drop as chorus to verse; a heuristic, labelled as one.
  class ClipFinder
    FRAME_MS = 500
    TARGET_MS = 25_000
    MIN_MS = 24_000
    MAX_MS = 26_000
    SPAN = 16 # frames each side of a boundary (8 s)
    MIN_NOVELTY = 2.5 # dB, summed over bands
    DIRECTION_DB = 1.5
    PEAK_RADIUS = 6 # frames (3 s)
    SNAP_MS = 1_000 # snap a boundary to a cut this close
    SEAM_MARGIN_MS = 6_000 # a seam sits at least this far inside the window
    BODY_DROP_DB = 6.0 # music body: smoothed level within this of the median
    SILENT_DB = -45.0
    SINGER_WEIGHT = 6.0
    NOVELTY_CAP = 10.0 # the intro and outro steps are huge; they must not outvote the song
    SEAMS = %w[verse_to_chorus chorus_to_verse singer_change section_change unknown].freeze

    Boundary = Data.define(:ms, :novelty, :seam)
    Proposal = Data.define(:ordinal, :start_ms, :end_ms, :seam, :seam_ms, :cast_shape, :target_performer,
                           :performer_ordinals, :score)

    # bands: { "low" => [dB per frame], "mid" => [...], "high" => [...], "full" => [...] }
    # silences: [[start_ms, end_ms]]; cuts: [ms]; sections: caption_timing sections.
    def initialize(bands:, silences: [], cuts: [], sections: [], performers: [], count: 5)
      @bands = %w[low mid high].map { |b| bands.fetch(b) }
      @full = bands.fetch("full")
      @silences = silences
      @cuts = cuts.sort
      @sections = sections
      @performers = performers
      @count = count
    end

    # [first_ms, last_ms] of the music: the smoothed level within BODY_DROP_DB of
    # the median. Intro and outro fall outside; a dropout inside is caught by
    # continuous?, not here.
    def body
      @body ||= begin
        smooth = @full.each_index.map { |i| mean(@full[[i - 4, 0].max, 8]) }
        audible = @full.select { |db| db > SILENT_DB }.sort
        floor = (audible[audible.size / 2] || 0.0) - BODY_DROP_DB
        loud = smooth.each_index.select { |i| smooth[i] >= floor }
        loud.empty? ? [0, 0] : [loud.first * FRAME_MS, (loud.last + 1) * FRAME_MS]
      end
    end

    def boundaries
      @boundaries ||= (energy_boundaries + caption_boundaries).sort_by(&:ms)
    end

    def singer_changes
      @singer_changes ||= ClipCast.singer_changes(@performers).map { |ms| Boundary.new(ms, SINGER_WEIGHT, "singer_change") }
    end

    def proposals
      picked = []
      candidates.sort_by { |c| -c.score }.each do |c|
        next if picked.any? { |p| c.start_ms < p.end_ms && p.start_ms < c.end_ms }

        picked << c
        break if picked.size == @count
      end
      picked.sort_by(&:start_ms).each_with_index.map { |p, i| p.with(ordinal: i + 1) }
    end

    def candidates
      boundaries.filter_map { |b| window_from(b) }
    end

    private

    def window_from(boundary)
      start = snap(boundary.ms, boundary.ms - SNAP_MS, boundary.ms + SNAP_MS)
      start = body.first if start < body.first && boundary.ms >= body.first - SNAP_MS # the music's own start
      finish = snap(start + TARGET_MS, start + MIN_MS, start + MAX_MS)
      return unless continuous?(start, finish)

      inside = (boundaries + singer_changes).select { |s| s.ms.between?(start + SEAM_MARGIN_MS, finish - SEAM_MARGIN_MS) }
      seam = inside.max_by { |s| weight(s) + centrality(s.ms, start, finish) }
      return unless seam

      cast = ClipCast.label(@performers, start, finish)
      score = weight(seam) + 3 * centrality(seam.ms, start, finish) + 0.5 * weight(boundary) +
              (cast.cast_shape == "unknown" ? 0 : 2)
      Proposal.new(ordinal: nil, start_ms: start, end_ms: finish, seam: seam.seam, seam_ms: seam.ms,
                   cast_shape: cast.cast_shape, target_performer: cast.target, performer_ordinals: cast.present,
                   score: score.round(2))
    end

    # Inside the music body, no detected silence, no silent frame.
    def continuous?(start, finish)
      body_start, body_end = body
      return false unless start >= body_start && finish <= body_end
      return false if @silences.any? { |s, e| s < finish && start < e }

      @full[(start / FRAME_MS)...(finish / FRAME_MS)].all? { |db| db > SILENT_DB }
    end

    def weight(boundary) = [boundary.novelty, NOVELTY_CAP].min

    def centrality(ms, start, finish) = 1.0 - ((ms - ((start + finish) / 2.0)).abs / ((finish - start) / 2.0))

    # The cut in [lo, hi] closest to target, else the target itself.
    def snap(target, lo, hi)
      @cuts.select { |c| c.between?(lo, hi) }.min_by { |c| (c - target).abs } || target
    end

    def energy_boundaries
      n = @full.size
      novelty = (0...n).map { |i| i < SPAN || i + SPAN > n ? 0.0 : deltas(i).sum(&:abs) }
      (0...n).filter_map do |i|
        next if novelty[i] < MIN_NOVELTY
        next unless novelty[[i - PEAK_RADIUS, 0].max..[i + PEAK_RADIUS, n - 1].min].max == novelty[i]
        next if novelty[[i - PEAK_RADIUS, 0].max...i].include?(novelty[i]) # a plateau counts once

        rise = deltas(i).sum
        seam = if rise >= DIRECTION_DB then "verse_to_chorus"
               elsif rise <= -DIRECTION_DB then "chorus_to_verse"
               else "section_change"
               end
        Boundary.new(i * FRAME_MS, novelty[i].round(2), seam)
      end
    end

    # Caption sections (vocal/instrumental) mark section changes: timings only.
    def caption_boundaries
      Array(@sections).drop(1).map { |s| Boundary.new(s["start_ms"], MIN_NOVELTY, "section_change") }
    end

    # Silent frames are left out: a dropout is not a section.
    def deltas(i)
      after = (i...(i + SPAN)).select { |j| audible?(j) }
      before = ((i - SPAN)...i).select { |j| audible?(j) }
      @bands.map { |b| mean(b.values_at(*after)) - mean(b.values_at(*before)) }
    end

    def audible?(frame) = @full[frame] > SILENT_DB

    def mean(list) = list.empty? ? 0.0 : list.sum / list.size.to_f
  end
end
