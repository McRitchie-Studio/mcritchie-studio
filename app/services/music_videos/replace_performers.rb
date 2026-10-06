module MusicVideos
  # The cast seam: the agent's vision pass posts the whole performer set and it
  # replaces what is there. Operator labels and recasts on the old set are
  # dropped (the grouping may have changed), and each count dropped is
  # reported. A confirmed cast is never replaced. Any chunks already cut are
  # relabelled from the new set (LabelChunks). The agent sends FIELDS and
  # nothing else: who a performer is, and who replaces them, is the operator's.
  class ReplacePerformers
    FIELDS = %w[ordinal label still_object_keys sightings confidence_note].freeze
    SIGHTING_FIELDS = VideoPerformer::SIGHTING_KEYS

    class Refused < StandardError
      attr_reader :code

      def initialize(message, code)
        super(message)
        @code = code
      end
    end

    Outcome = Data.define(:performers, :dropped_labels, :dropped_recasts)

    def initialize(video, rows)
      @video = video
      @rows = rows
    end

    def check!
      check_shape!
      raise Refused.new("the cast is already confirmed", "CAST_CONFIRMED") if @video.cast_confirmed?
    end

    def call
      check!
      VideoPerformer.transaction do
        old = @video.video_performers.to_a
        dropped = old.count { |p| p.artist_slug.present? || p.extra? }
        dropped_recasts = old.count { |p| p.recast_person_slug.present? || p.recast_keep? }
        @video.video_performers.destroy_all
        performers = @rows.map { |row| @video.video_performers.create!(attributes(row)) }
        LabelChunks.call(@video) # chunks cut at digest learn who is on screen
        Outcome.new(performers:, dropped_labels: dropped, dropped_recasts:)
      end
    end

    private

    def check_shape!
      raise Refused.new("performers must be a non-empty list", "INVALID_PERFORMERS") unless @rows.is_a?(Array) && @rows.any?

      extra = @rows.flat_map do |row|
        next ["(not an object)"] unless row.is_a?(Hash)

        (row.keys - FIELDS) +
          Array(row["sightings"]).flat_map { |s| s.is_a?(Hash) ? s.keys - SIGHTING_FIELDS : [] }.map { |k| "sightings.#{k}" }
      end.uniq
      return if extra.empty?

      raise Refused.new("unpermitted keys (the operator sets artists and recasts): #{extra.join(', ')}", "UNPERMITTED_KEYS")
    end

    def attributes(row)
      {
        ordinal: row["ordinal"],
        label: row["label"],
        still_object_keys: Array(row["still_object_keys"]),
        sightings: Array(row["sightings"]).map { |s| s.is_a?(Hash) ? s.slice(*SIGHTING_FIELDS) : s },
        confidence_note: row["confidence_note"]
      }
    end
  end
end
