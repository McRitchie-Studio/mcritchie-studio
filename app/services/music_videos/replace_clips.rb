module MusicVideos
  # The clips seam: bin/find-clips posts the whole proposal set and it replaces
  # what is there. The clip files are already in R2; only their keys arrive.
  # The hub fills each prompt from the cast, so the template lives in one place
  # (ClipPrompt). Clips need a confirmed cast; approvals on the old set are
  # dropped and counted.
  class ReplaceClips
    FIELDS = %w[ordinal start_ms end_ms seam seam_ms cast_shape target_performer performer_ordinals object_key].freeze

    class Refused < StandardError
      attr_reader :code

      def initialize(message, code)
        super(message)
        @code = code
      end
    end

    Outcome = Data.define(:clips, :dropped_approvals)

    def initialize(video, rows)
      @video = video
      @rows = rows
    end

    def check!
      raise Refused.new("clips must be a non-empty list", "INVALID_CLIPS") unless @rows.is_a?(Array) && @rows.any?

      extra = @rows.flat_map { |row| row.is_a?(Hash) ? row.keys - FIELDS : ["(not an object)"] }.uniq
      raise Refused.new("unpermitted keys (the hub fills the prompt): #{extra.join(', ')}", "UNPERMITTED_KEYS") if extra.any?
      return if @video.cast_confirmed?

      raise Refused.new("the cast is not confirmed yet: #{@video.cast_blocker || 'confirm it first'}", "CAST_NOT_CONFIRMED")
    end

    def call
      check!
      VideoClip.transaction do
        @video.lock!
        dropped = @video.video_clips.where(status: "approved").count
        @video.video_clips.destroy_all
        clips = @rows.map { |row| @video.video_clips.create!(row.slice(*FIELDS).merge("prompt" => prompt_for(row))) }
        @video.sync_clip_stage!
        Outcome.new(clips:, dropped_approvals: dropped)
      end
    end

    private

    def prompt_for(row)
      people = @video.video_performers.index_by(&:ordinal)
      target = people[row["target_performer"]]
      present = Array(row["performer_ordinals"]).filter_map { |n| people[n] } - [target]
      labelled, background = present.partition(&:artist_slug)
      ClipPrompt.fill(target: target&.label, others: labelled.map(&:label), background: background.any?)
    end
  end
end
