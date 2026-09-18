class Release
  # WHERE A RELEASE'S TIME ACTUALLY GOES — the read behind the /deployments DevOps
  # summary card and its sidebar.
  #
  # WHY IT EXISTS, when Release.deployment_stage_averages already averages the stages.
  # Two things made that card's numbers true but misleading, measured on production
  # 2026-09-18 over the last 10 shipped releases:
  #
  #   THE STAGES OVERLAP. G3 Candidate runs INSIDE Assembled (2:08p→2:24p against
  #   2:07p→2:23p) and Deployed runs INSIDE G4 Ship. So the four stage averages
  #   cannot be added up, and their sum does not equal Total — which reads as an
  #   arithmetic error to anyone who tries.
  #
  #   THE MEAN IS TWO OUTLIERS. Total averaged 2h 39m while the MEDIAN was ~1h: two
  #   releases (9h 59m and 8h 52m) sat open for hours collecting reviewed work
  #   before QA ever started. The mean described neither the typical release nor
  #   the slow ones.
  #
  # So this splits each release into FOUR PHASES THAT TILE THE TOTAL — wall-clock
  # boundaries, clamped to run forward, so the phases always sum to exactly
  # created_at → shipped_at:
  #
  #   batch  created_at → first G3 attempt starts   the candidate is open, collecting work
  #   qa     → assembled_at                         candidate CI + QA deploy (G3 inside)
  #   hold   → first G4 attempt starts              QA-green, waiting for the ship
  #   ship   → shipped_at                           G4 gate + production deploy
  #
  # The FIRST attempt of each gate marks the boundary, not the latest: a G3 retried
  # three times was doing QA the whole while, and starting the phase at the third
  # attempt would bill the first two to "batch".
  #
  # A missing stamp collapses its phase to zero rather than inventing time — the
  # boundary falls back to the previous one. Read-only; two queries plus one for the
  # mascots, regardless of the window.
  class Flow
    PHASES = [
      { key: "batch", label: "Batch", hint: "open, collecting reviewed work" },
      { key: "qa",    label: "QA",    hint: "candidate CI + QA deploy (G3)" },
      { key: "hold",  label: "Hold",  hint: "QA-green, waiting to ship" },
      { key: "ship",  label: "Ship",  hint: "G4 gate + production deploy" }
    ].freeze
    PHASE_KEYS = PHASES.map { |phase| phase[:key] }.freeze

    # A release whose total runs past this multiple of the median is called out by
    # name. Three is where the production window separates cleanly: the eight
    # ordinary releases sit within 2x of the median, the two long ones past 8x.
    OUTLIER_FACTOR = 3

    Entry = Struct.new(:slug, :mascot, :shipped_at, :total, :phases, keyword_init: true) do
      def phase(key) = phases.fetch(key.to_s, 0)

      # The phase that ate most of this release's time — what an outlier is named for.
      def dominant_phase = phases.max_by { |_key, seconds| seconds }&.first
    end

    attr_reader :entries

    def self.recent(limit: DEPLOYMENT_DASHBOARD_SAMPLE)
      releases = Release.where(state: "shipped")
                        .where.not(shipped_at: nil)
                        .order(shipped_at: :desc)
                        .includes(:gate_runs)
                        .limit(limit).to_a
      mascots = Pokemon.where(slug: releases.filter_map { |release| release.devops_field("mascot") })
                       .index_by(&:slug)
      new(releases.map { |release| entry_for(release, mascots[release.devops_field("mascot")]) })
    end

    def self.entry_for(release, mascot = nil)
      Entry.new(slug: release.slug, mascot: mascot, shipped_at: release.shipped_at,
                total: [(release.shipped_at - release.created_at).to_i, 0].max,
                phases: phases_for(release))
    end

    # The four phase durations, in seconds, keyed by PHASE_KEYS. Each boundary is
    # clamped between its predecessor and shipped_at, so the phases can neither go
    # negative nor overrun, and they sum to the release's total by construction.
    def self.phases_for(release)
      start = release.created_at
      # Never before the start: a skewed clock that stamped shipped_at first would
      # otherwise hand Comparable#clamp an inverted range, which raises.
      finish = [release.shipped_at, start].max
      raw = [first_gate_start(release, "g3_candidate") || release.assembled_at,
             release.assembled_at,
             first_gate_start(release, "g4_ship") || release.prod_deploy_started_at]

      boundaries = raw.each_with_object([start]) do |at, acc|
        acc << (at ? at.clamp(acc.last, finish) : acc.last)
      end
      boundaries << finish

      PHASE_KEYS.each_with_index.to_h do |key, index|
        [key, (boundaries[index + 1] - boundaries[index]).to_i]
      end
    end

    # Filtered in Ruby off the preloaded association, like Release#latest_gate_run,
    # so a window of releases costs no query per row.
    def self.first_gate_start(release, key)
      release.gate_runs.select { |run| run.key == key }.filter_map(&:started_at).min
    end

    def initialize(entries)
      @entries = entries
    end

    def any? = entries.any?
    def size = entries.size

    def median_total = median(entries.map(&:total))

    def mean_total
      return nil if entries.empty?

      (entries.sum(&:total).to_f / entries.size).round
    end

    # The TYPICAL composition: each phase's own median. Deliberately not the share
    # of the summed time — that is dominated by the outliers' batching, which is the
    # very distortion this object exists to take out of the headline.
    def phase_median(key) = median(entries.map { |entry| entry.phase(key) })

    # Where the window's time went in aggregate, as a fraction of the summed total —
    # the "outliers included" view the sidebar shows beside the medians, so the
    # distortion is visible rather than hidden.
    def phase_share(key)
      sum = entries.sum(&:total)
      return 0.0 if sum.zero?

      entries.sum { |entry| entry.phase(key) }.to_f / sum
    end

    def outliers
      median = median_total
      return [] if median.nil? || median.zero?

      entries.select { |entry| entry.total > median * OUTLIER_FACTOR }
    end

    # Oldest first — the order a sparkline reads, newest at the right edge.
    def chronological = entries.reverse

    # The bar scale for the sparkline: the tallest ORDINARY release, never an
    # outlier. Scaling to the outlier would flatten the other eight to a pixel and
    # hide the typical run the card leads with; an outlier is drawn clipped at full
    # height and marked instead. Floors at 1 so an all-zero window cannot divide.
    def scale_seconds
      ordinary = entries - outliers
      [(ordinary.presence || entries).map(&:total).max.to_i, 1].max
    end

    private

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round
    end
  end
end
