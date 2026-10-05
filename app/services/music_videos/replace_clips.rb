module MusicVideos
  # The clips seam: bin/find-clips posts a whole set and it replaces what is
  # there OF THAT KIND. The seam candidates and the chunks (bin/find-clips
  # --tile) coexist: posting one never touches the other. The clip files are
  # already in R2; only their keys arrive. The hub fills each prompt from the
  # cast and its recasts (ClipPrompts), so the template lives in one place (ClipPrompt). Clips need a
  # confirmed cast; approvals on the old set are dropped and counted.
  #
  # A chunk set arrives with the chunk length and overlap it was cut at (25 s
  # and 5 s unless sent); the video records them with the set. A chunk cut at
  # the same window as before keeps its "request regenerate" flag, and its
  # takes find it again by that window (VideoChunkTake#for?).
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

    def initialize(video, rows, kind: "candidate", chunk_ms: nil, chunk_overlap_ms: nil)
      @video = video
      @rows = rows
      @kind = kind
      @sent_tiling = !(chunk_ms.nil? && chunk_overlap_ms.nil?)
      @tiling = { chunk_ms: chunk_ms || ChunkTiler::CHUNK_MS, overlap_ms: chunk_overlap_ms || ChunkTiler::OVERLAP_MS }
    end

    def check!
      raise Refused.new("kind must be one of: #{VideoClip::KINDS.join(', ')}", "INVALID_KIND") unless VideoClip::KINDS.include?(@kind)
      raise Refused.new("clips must be a non-empty list", "INVALID_CLIPS") unless @rows.is_a?(Array) && @rows.any?
      if @sent_tiling && !chunk?
        raise Refused.new("chunk_ms and chunk_overlap_ms are for kind chunk only", "UNPERMITTED_KEYS")
      end

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
        flags = chunk? ? regenerate_flags(old) : {}
        old.destroy_all
        @video.update!(chunk_ms: @tiling[:chunk_ms], chunk_overlap_ms: @tiling[:overlap_ms]) if chunk?
        clips = @rows.map do |row|
          clip = @video.video_clips.build(row.slice(*fields).merge("kind" => @kind))
          clip.prompt = ClipPrompts.for(clip)
          clip.assign_attributes(flags.fetch([clip.ordinal, clip.start_ms, clip.end_ms], {}))
          clip.tap(&:save!)
        end
        @video.sync_clip_stage!
        Outcome.new(clips:, dropped_approvals: dropped)
      end
    end

    private

    def chunk? = @kind == "chunk"

    def fields = chunk? ? CHUNK_FIELDS : FIELDS

    # [ordinal, start_ms, end_ms] => the operator's pending regenerate request.
    def regenerate_flags(chunks)
      chunks.where.not(regenerate_requested_at: nil).to_h do |c|
        [[c.ordinal, c.start_ms, c.end_ms], c.slice(:regenerate_requested_at, :regenerate_note)]
      end
    end

    # A chunk set is the whole tiling or nothing: the stitch needs every
    # chunk, in order, each overlapping the next by the overlap, the last
    # ending at the video's end.
    def check_tiling!
      why = ChunkTiler.problem(**@tiling)
      raise Refused.new(why, "INVALID_TILING") if why

      spans = @rows.map { |row| row.values_at("ordinal", "start_ms", "end_ms") }.sort_by { |s| s.first.to_i }
      last_end = spans.last.last
      expected = last_end.is_a?(Integer) && last_end.positive? ? ChunkTiler.windows(last_end, **@tiling).map { |w| w.to_h.values } : nil
      unless spans == expected
        raise Refused.new("chunks must tile the video from 0: #{@tiling[:chunk_ms]} ms chunks on a " \
                          "#{ChunkTiler.stride(**@tiling)} ms stride, numbered from 1, only the last one shorter", "INVALID_TILING")
      end

      duration = @video.duration_ms
      return if duration.nil? || last_end.between?(duration - ChunkTiler::END_TOLERANCE_MS, duration)

      raise Refused.new("the last chunk ends at #{last_end} ms but the video runs #{duration} ms: tile the whole video",
                        "INVALID_TILING")
    end
  end
end
