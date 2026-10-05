module MusicVideos
  # The clips seam: bin/find-clips posts a whole set and it replaces what is
  # there OF THAT KIND. The seam candidates and the chunks (bin/find-clips
  # --tile) coexist: posting one never touches the other. The clip files are
  # already in R2; only their keys arrive. The hub fills each prompt from the
  # cast, so the template lives in one place (ClipPrompt). Clips need a
  # confirmed cast; approvals on the old set are dropped and counted.
  class ReplaceClips
    FIELDS = %w[ordinal start_ms end_ms seam seam_ms cast_shape target_performer performer_ordinals object_key].freeze
    CHUNK_FIELDS = (FIELDS - %w[seam seam_ms]).freeze

    class Refused < StandardError
      attr_reader :code

      def initialize(message, code)
        super(message)
        @code = code
      end
    end

    Outcome = Data.define(:clips, :dropped_approvals)

    def initialize(video, rows, kind: "candidate")
      @video = video
      @rows = rows
      @kind = kind
    end

    def check!
      raise Refused.new("kind must be one of: #{VideoClip::KINDS.join(', ')}", "INVALID_KIND") unless VideoClip::KINDS.include?(@kind)
      raise Refused.new("clips must be a non-empty list", "INVALID_CLIPS") unless @rows.is_a?(Array) && @rows.any?

      extra = @rows.flat_map { |row| row.is_a?(Hash) ? row.keys - fields : ["(not an object)"] }.uniq
      raise Refused.new("unpermitted keys (#{chunk? ? 'a chunk has no seam, and ' : ''}the hub fills the prompt): #{extra.join(', ')}", "UNPERMITTED_KEYS") if extra.any?

      check_tiling! if chunk?
      return if @video.cast_confirmed?

      raise Refused.new("the cast is not confirmed yet: #{@video.cast_blocker || 'confirm it first'}", "CAST_NOT_CONFIRMED")
    end

    def call
      check!
      VideoClip.transaction do
        @video.lock!
        old = @video.video_clips.where(kind: @kind)
        dropped = old.where(status: "approved").count
        old.destroy_all
        clips = @rows.map do |row|
          @video.video_clips.create!(row.slice(*fields).merge("kind" => @kind, "prompt" => prompt_for(row)))
        end
        @video.sync_clip_stage!
        Outcome.new(clips:, dropped_approvals: dropped)
      end
    end

    private

    def chunk? = @kind == "chunk"

    def fields = chunk? ? CHUNK_FIELDS : FIELDS

    # A chunk set is the whole tiling or nothing: the stitch needs every
    # chunk, in order, each overlapping the next by 5 s, the last ending at
    # the video's end.
    def check_tiling!
      spans = @rows.map { |row| row.values_at("ordinal", "start_ms", "end_ms") }.sort_by { |s| s.first.to_i }
      last_end = spans.last.last
      expected = last_end.is_a?(Integer) && last_end.positive? ? ChunkTiler.windows(last_end).map(&:to_h).map(&:values) : nil
      unless spans == expected
        raise Refused.new("chunks must tile the video from 0: 25 s on a 20 s stride, numbered from 1, only the last one shorter",
                          "INVALID_TILING")
      end

      duration = @video.duration_ms
      return if duration.nil? || last_end.between?(duration - ChunkTiler::END_TOLERANCE_MS, duration)

      raise Refused.new("the last chunk ends at #{last_end} ms but the video runs #{duration} ms: tile the whole video",
                        "INVALID_TILING")
    end

    def prompt_for(row)
      people = @video.video_performers.index_by(&:ordinal)
      target = people[row["target_performer"]]
      present = Array(row["performer_ordinals"]).filter_map { |n| people[n] } - [target]
      labelled, background = present.partition(&:artist_slug)
      ClipPrompt.fill(target: target&.label, others: labelled.map(&:label), background: background.any?)
    end
  end
end
