module Api
  module V1
    # The digest seam: bin/digest-video (agent side) posts a downloaded video
    # here after uploading it to R2. Caption text never crosses: any key beyond
    # the known fields is refused rather than silently dropped.
    class MusicVideosController < BaseController
      FIELDS = %w[kind platform source_url source_id title uploader credited_artists duration_ms
                  source_object_key info_object_key caption_timing].freeze
      TIMING_KEYS = %w[cues sections].freeze
      PERFORMER_FIELDS = %w[ordinal label artist_slug extra still_object_keys sightings confidence_note].freeze
      CLIP_FIELDS = (MusicVideos::ReplaceClips::FIELDS + %w[kind prompt status]).freeze

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

      # Stage 2: the vision pass replaces the video's performer set. Stills are
      # already in R2; only their keys arrive. Artists and recasts are the
      # operator's call: a row carrying either is refused whole.
      def performers
        video = MusicVideo.find_by!(slug: params[:slug])
        replace = MusicVideos::ReplacePerformers.new(video, params.to_unsafe_h["performers"])
        replace.check! # a refusal is an answer, not an ErrorLog
        outcome = rescue_and_log(target: video) { replace.call }
        render_data(serialize(video.reload), meta: { dropped_labels: outcome.dropped_labels, dropped_recasts: outcome.dropped_recasts })
      rescue MusicVideos::ReplacePerformers::Refused => e
        render_error(e.message, status: e.code == "CAST_CONFIRMED" ? :conflict : :unprocessable_entity,
                                error_code: e.code)
      end

      # Stage 5: bin/find-clips replaces one kind of the video's clips: the
      # seam candidates (the default, once the cast is confirmed), or with kind
      # "chunk" the tiling, cut at chunk_ms and chunk_overlap_ms (25 s and 5 s
      # unless sent), which bin/digest-video posts before anyone is cast. The
      # other kind is left alone. Clip files are already in R2; the hub fills
      # each prompt from the cast as it stands.
      def clips
        video = MusicVideo.find_by!(slug: params[:slug])
        body = params.to_unsafe_h
        replace = MusicVideos::ReplaceClips.new(video, body["clips"], kind: body.fetch("kind", "candidate"),
                                                                        **body.slice("chunk_ms", "chunk_overlap_ms").symbolize_keys)
        replace.check! # a refusal is an answer, not an ErrorLog
        outcome = rescue_and_log(target: video) { replace.call }
        render_data(serialize(video.reload), meta: { dropped_approvals: outcome.dropped_approvals })
      rescue MusicVideos::ReplaceClips::Refused => e
        render_error(e.message, status: e.code == "CAST_NOT_CONFIRMED" ? :conflict : :unprocessable_entity,
                                error_code: e.code)
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
        video.as_json(only: %w[slug kind platform source_url source_id title duration_ms stage chunk_ms chunk_overlap_ms
                               source_object_key info_object_key caption_timing unresolved_credits])
             .merge("artists" => credits.map do |c|
               { "slug" => c.artist_slug, "name" => c.artist.name, "kind" => c.artist.kind,
                 "role" => c.role, "position" => c.position }
             end, "performers" => video.video_performers.map { |p| p.as_json(only: PERFORMER_FIELDS) },
                  "clips" => video.clip_candidates.map { |c| c.as_json(only: CLIP_FIELDS) },
                  "chunks" => video.video_chunks.map { |c| c.as_json(only: CLIP_FIELDS + %w[reference_frames]) },
                  "alt_videos" => video.alt_videos.order(:number).map { |a| a.as_json(only: %w[number slug swaps]) })
      end
    end
  end
end
