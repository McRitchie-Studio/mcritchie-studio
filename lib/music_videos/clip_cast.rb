# frozen_string_literal: true

module MusicVideos
  # Who is on screen in a clip window, from the confirmed cast's sightings
  # (samples every ~3 s). A principal is a performer linked to an artist and
  # seen clearly in the window; everyone else present is background.
  module ClipCast
    COUNTS = %w[solo duo trio group].freeze
    SHAPES = (COUNTS.flat_map { |c| [c, "#{c}_plus_background"] } + ["unknown"]).freeze
    TOLERANCE_MS = 1_500 # half the sample spacing
    SINGER_GAP_MS = 6_000 # two sightings further apart than this are not a handover

    Label = Data.define(:cast_shape, :target, :present)

    module_function

    # performers: rows as the API serialises them (ordinal, artist_slug, extra, sightings).
    def label(performers, start_ms, end_ms)
      seen = performers.filter_map do |p|
        hits = Array(p["sightings"]).select { |s| s["t_ms"].between?(start_ms - TOLERANCE_MS, end_ms + TOLERANCE_MS) }
        [p, hits] if hits.any?
      end
      principals = seen.select { |p, hits| principal?(p) && hits.any? { |s| s["visibility"] == "clear" } }
      background = seen.size > principals.size
      shape = principals.empty? ? "unknown" : "#{COUNTS[[principals.size, 4].min - 1]}#{'_plus_background' if background}"
      target = principals.max_by { |p, hits| [hits.count { |s| s["visibility"] == "clear" }, hits.size, -p["ordinal"]] }
      Label.new(cast_shape: shape, target: target&.first&.fetch("ordinal"), present: seen.map { |p, _| p["ordinal"] }.sort)
    end

    # Moments where the one principal on screen hands over to another: the
    # midpoint between consecutive lone-principal sightings of different people.
    def singer_changes(performers)
      at = Hash.new { |h, k| h[k] = [] }
      performers.select { |p| principal?(p) }.each do |p|
        Array(p["sightings"]).each { |s| at[s["t_ms"]] << p["ordinal"] if s["visibility"] == "clear" }
      end
      lone = at.select { |_t, who| who.uniq.size == 1 }.sort
      lone.each_cons(2).filter_map do |(t1, a), (t2, b)|
        (t1 + t2) / 2 if a.first != b.first && t2 - t1 <= SINGER_GAP_MS
      end
    end

    def principal?(performer) = !performer["artist_slug"].to_s.empty? && !performer["extra"]
  end
end
