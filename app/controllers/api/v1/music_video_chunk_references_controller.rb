module Api
  module V1
    # A chunk's lettered reference frames (recast pipeline, piece 16), as
    # bin/clip-references --apply posts them:
    #
    #   POST /api/v1/music_videos/:slug/chunks/:ordinal/references
    #        { frames: [{ object_key, t_ms, letters }] }
    #
    # The JPEGs are already in R2 (.../chunks/refs/); only their keys arrive.
    # The set replaces the chunk's frames whole, and the chunk's stored prompt is
    # refilled (it says the people are marked once frames exist). A key the hub
    # does not know, at the top or on a frame, refuses the whole post.
    class MusicVideoChunkReferencesController < BaseController
      TOP_KEYS = %w[frames].freeze
      # Rails adds these to every JSON body (the path, and the params wrapper's
      # copy of the body); they are not the caller's keys.
      ROUTING_KEYS = %w[controller action music_video_slug chunk_ordinal format music_video_chunk_reference].freeze

      def create
        video = MusicVideo.find_by!(slug: params[:music_video_slug])
        chunk = video.video_chunks.find_by!(ordinal: params[:chunk_ordinal])
        body = params.to_unsafe_h.except(*ROUTING_KEYS)
        refusal = refusal_for(body)
        return render_error(refusal.first, error_code: refusal.last) if refusal

        chunk.association(:music_video).target = video
        chunk.reference_frames = body["frames"].map { |f| f.to_h.slice(*VideoClip::REFERENCE_KEYS) }
        chunk.prompt = MusicVideos::ClipPrompts.for(chunk)
        # A refusal is an answer, not an ErrorLog.
        return render_error(chunk.errors.full_messages.to_sentence, error_code: "INVALID_FRAMES") unless chunk.valid?

        rescue_and_log(target: video) { chunk.save! }
        render_data(chunk.as_json(only: %w[ordinal start_ms end_ms reference_frames]), status: :created)
      end

      private

      # [message, code] or nil.
      def refusal_for(body)
        extra = body.keys - TOP_KEYS
        return ["unpermitted keys: #{extra.join(', ')}", "UNPERMITTED_KEYS"] if extra.any?

        frames = body["frames"]
        return ["frames must be a non-empty list", "INVALID_FRAMES"] unless frames.is_a?(Array) && frames.any?

        bad = frames.flat_map { |f| f.is_a?(Hash) ? f.keys - VideoClip::REFERENCE_KEYS : ["(not an object)"] }.uniq
        ["unpermitted frame keys: #{bad.join(', ')}", "UNPERMITTED_KEYS"] if bad.any?
      end
    end
  end
end
