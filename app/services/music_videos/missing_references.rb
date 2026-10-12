# frozen_string_literal: true

module MusicVideos
  # Which chunks still owe their lettered reference frames (the A/B/C stills
  # bin/clip-references makes; digest-video Stage 2, step 5).
  #
  # A chunk owes them when people are on screen in its window and it has no
  # frames. "People on screen" is the cast's sightings, read by the same rule
  # LabelChunks and bin/clip-references use (ClipCast.label: any performer
  # sighted inside the window, give or take ClipCast::TOLERANCE_MS). A chunk no
  # sighting falls in (credits, black, a title card) owes nothing.
  #
  # Pure: it reads the chunks and performers the caller already loaded and
  # queries nothing, so the alt video page and the asset zip ask it once.
  module MissingReferences
    CAST_FIELDS = %w[ordinal artist_slug extra sightings].freeze

    module_function

    # The chunks (VideoClip, kind chunk) that owe frames, in ordinal order.
    def chunks(chunks, performers)
      cast = performers.map { |p| p.as_json(only: CAST_FIELDS) }
      chunks.compact.select { |chunk| owes?(chunk, cast) }.sort_by(&:ordinal)
    end

    # The warning the alt video page and the zip README both carry, or nil
    # when nothing is missing. missing: how many chunks owe frames; total: how
    # many clips the page or zip covers (one chunk each).
    def warning(missing, total)
      return if missing.zero?

      verb = missing == 1 ? "has" : "have"
      "#{missing} of #{total} #{'clip'.pluralize(total)} #{verb} no A/B/C frames yet. " \
        "Higgsfield works best with them: ask the agent to run lettered references."
    end

    def owes?(chunk, cast)
      chunk.reference_frame_list.empty? && ClipCast.label(cast, chunk.start_ms, chunk.end_ms).present.any?
    end
  end
end
