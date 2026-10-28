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

    # A gem release's own history is used for an in-flight gem release's estimate only
    # once it has this many samples; below it, the overall window is the better guess.
    GEM_HISTORY_MIN = 3

    # How far back to look for gem releases. Gem releases are rarer than app releases,
    # so the window that finds ten of them is wider than the ten-release card window.
    GEM_HISTORY_SCAN = 50

    Entry = Struct.new(:slug, :mascot, :mascot_name, :shipped_at, :total, :phases, keyword_init: true) do
      def phase(key) = phases.fetch(key.to_s, 0)

      # The phase that ate most of this release's time — what an outlier is named for.
      def dominant_phase = phases.max_by { |_key, seconds| seconds }&.first
    end

    # THE COUNTDOWN — where an in-flight release is and when it should land.
    #
    #   phase            the PHASE_KEYS key it is in now
    #   phase_started_at when that phase began (the same boundary phases_for uses)
    #   elapsed          seconds since the release opened
    #   remaining        seconds still expected: max(phase median − time in phase, 0)
    #                    plus the medians of every later phase
    #   overrun          seconds the current phase has run past its median (0 if not)
    #   eta              the moment to count down to. now + remaining while time is
    #                    left; once nothing is left (an overrun in the last phase) it is
    #                    the moment the release was DUE, so the clock counts the overrun
    #                    up from it ("+12m over") instead of sitting at zero
    #   gem_history      true when the medians came from gem releases only
    Estimate = Struct.new(:phase, :phase_started_at, :elapsed, :remaining, :overrun, :eta, :gem_history,
                          keyword_init: true) do
      def over? = remaining.zero? && overrun.positive?

      def phase_label = PHASES.find { |p| p[:key] == phase }&.dig(:label)
    end

    attr_reader :entries

    def self.recent(limit: DEPLOYMENT_DASHBOARD_SAMPLE)
      new(entries_for(shipped_scope.limit(limit).to_a))
    end

    # The last `limit` shipped releases that carried a gem member — the history a gem
    # release is estimated from. Scans a wider window and filters in Ruby off the
    # preloaded tasks (Task#gem_release? reads shape and repo, not a column).
    def self.recent_gem(limit: DEPLOYMENT_DASHBOARD_SAMPLE, scan: GEM_HISTORY_SCAN)
      releases = shipped_scope.includes(:tasks).limit(scan).to_a
      new(entries_for(releases.select { |release| carries_gem?(release) }.first(limit)))
    end

    # The in-flight release's estimate, from the history that fits it: a release
    # carrying a gem reads gem-release history when there are GEM_HISTORY_MIN samples,
    # else the overall window `default`. nil with no release or no history.
    def self.estimate_for(release, default:, now: Time.current, gem_history: nil)
      return nil if release.nil? || !release.active?

      if carries_gem?(release)
        gem_flow = gem_history || recent_gem
        return gem_flow.estimate(release, now: now, gem_history: true) if gem_flow.size >= GEM_HISTORY_MIN
      end
      default&.estimate(release, now: now)
    end

    def self.carries_gem?(release) = release.tasks.any?(&:gem_release?)

    def self.shipped_scope
      Release.where(state: "shipped").where.not(shipped_at: nil).order(shipped_at: :desc).includes(:gate_runs)
    end

    def self.entries_for(releases)
      mascots = Pokemon.where(slug: releases.filter_map { |release| release.devops_field("mascot") })
                       .index_by(&:slug)
      genders = conductor_genders(releases)
      releases.map do |release|
        entry_for(release, mascots[release.devops_field("mascot")], gender: genders[release.slug])
      end
    end

    def self.entry_for(release, mascot = nil, gender: release.mascot_gender)
      Entry.new(slug: release.slug, mascot: mascot, mascot_name: mascot&.display_name(gender: gender),
                shipped_at: release.shipped_at,
                total: [(release.shipped_at - release.created_at).to_i, 0].max,
                phases: phases_for(release))
    end

    # { release slug => conductor gender } in ONE query: the stamped
    # devops.mascot_gender, else (a release stamped before the sign rule) its
    # conductor session's SessionMascot gender — Release#mascot_gender, batched.
    def self.conductor_genders(releases)
      stamped, unstamped = releases.partition { |release| release.devops.key?("mascot_gender") }
      by_session = SessionMascot.where(session_id: unstamped.filter_map { |r| r.devops_field("mascot_session") })
                                .pluck(:session_id, :mascot_slug, :gender)
                                .to_h { |sid, slug, gender| [[sid, slug], gender] }
      stamped.to_h { |release| [release.slug, release.mascot_gender] }
             .merge(unstamped.to_h { |release| [release.slug, by_session[[release.devops_field("mascot_session"), release.devops_field("mascot")]]] })
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

    # When each phase of a release STARTED, keyed by PHASE_KEYS, nil where it has not
    # (yet). The same stamps phases_for reads, unclamped: an in-flight release has no
    # shipped_at to clamp against, and a later phase that has begun is where it is.
    def self.phase_starts(release)
      { "batch" => release.created_at,
        "qa" => first_gate_start(release, "g3_candidate") || release.assembled_at,
        "hold" => release.assembled_at,
        "ship" => first_gate_start(release, "g4_ship") || release.prod_deploy_started_at }
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

    # THE ESTIMATE for one in-flight release, against this window's medians. Pure: the
    # clock is an argument. The phase it is in is the LATEST phase that has started;
    # a phase with no history (median nil) expects nothing. nil for an empty window.
    def estimate(release, now: Time.current, gem_history: false)
      return nil unless any?

      starts = self.class.phase_starts(release)
      index = PHASE_KEYS.rindex { |key| starts[key] } || 0
      phase = PHASE_KEYS[index]
      phase_started_at = [starts[phase] || release.created_at, now].min
      in_phase = (now - phase_started_at).to_i
      median = phase_median(phase).to_i
      later = PHASE_KEYS.drop(index + 1).sum { |key| phase_median(key).to_i }
      remaining = [median - in_phase, 0].max + later
      overrun = [in_phase - median, 0].max
      eta = remaining.positive? ? now + remaining : phase_started_at + median

      Estimate.new(phase: phase, phase_started_at: phase_started_at,
                   elapsed: [(now - release.created_at).to_i, 0].max,
                   remaining: remaining, overrun: overrun, eta: eta, gem_history: gem_history)
    end

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
