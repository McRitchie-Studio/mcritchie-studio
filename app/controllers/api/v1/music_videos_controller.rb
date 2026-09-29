module Api
  module V1
    # The digest seam: bin/digest-video (agent side) posts a downloaded video
    # here after uploading it to R2. Caption text never crosses: any key beyond
    # the known fields is refused rather than silently dropped.
    class MusicVideosController < BaseController
      FIELDS = %w[platform source_url source_id title uploader credited_artists duration_ms
                  source_object_key info_object_key caption_timing].freeze
      TIMING_KEYS = %w[cues sections].freeze

      def show
        render_data(serialize(MusicVideo.find_by!(slug: params[:slug])))
      end

      def create
        raw = params.require(:music_video).to_unsafe_h
        extra = unpermitted_keys(raw)
        if extra.any?
          return render_error("unpermitted keys (caption text is never stored): #{extra.join(', ')}",
                              error_code: "UNPERMITTED_KEYS")
        end

        outcome = MusicVideos::Digest.new(raw).call
        render_data(serialize(outcome.video), status: outcome.created? ? :created : :ok)
      end

      private

      def unpermitted_keys(raw)
        extra = raw.keys - FIELDS
        timing = raw["caption_timing"]
        extra += timing.keys.map { |k| "caption_timing.#{k}" } - TIMING_KEYS.map { |k| "caption_timing.#{k}" } if timing.is_a?(Hash)
        extra
      end

      def serialize(video)
        credits = video.music_video_artists.includes(:artist).sort_by { |c| [c.role == "primary" ? 0 : 1, c.position] }
        video.as_json(only: %w[slug kind platform source_url source_id title duration_ms stage
                               source_object_key info_object_key caption_timing unresolved_credits])
             .merge("artists" => credits.map do |c|
               { "slug" => c.artist_slug, "name" => c.artist.name, "kind" => c.artist.kind,
                 "role" => c.role, "position" => c.position }
             end)
      end
    end
  end
end
