module Api
  module V1
    # The final stitch of an alt video as bin/stitch-video drives it (recast
    # pipeline, pieces 4 and 13): /api/v1/music_videos/:slug/alt_videos/:n/stitches.
    # The Mac has ffmpeg and the dyno does not, so the bin reads the waiting
    # request here, stitches, uploads the MP4 to R2 itself, and reports back.
    # Each stitch is served as the stitcher's request: its versions resolved to
    # their objects, the source key, and where the result goes.
    class MusicVideoStitchesController < BaseController
      before_action :set_video
      before_action :set_stitch, only: %i[start finish failed]

      # Every stitch, newest first, whether a new one may be requested, and the
      # primary versions a request made now would hold, resolved to objects.
      def index
        objects = @alt_video.clips.to_h { |c| [c.chunk_ordinal, c.primary_version&.object_key] }
        render_data({ "stitches" => @alt_video.stitches.reverse.map(&:as_request),
                      "alt_video" => @alt_video.number, "source_object_key" => @video.source_object_key,
                      "ready" => @alt_video.ready_to_stitch?, "blocker" => @alt_video.stitch_blocker,
                      "current_takes" => VideoStitch.takes_of(@alt_video.clips)
                                                    .map { |t| t.merge("object_key" => objects[t["ordinal"]]) } })
      end

      # Open a request from the primary versions, or hand back the one already
      # open for them. 201 when this call opened it.
      def create
        asking = MusicVideos::RequestStitch.new(@alt_video)
        asking.check! # a refusal is an answer, not an ErrorLog
        outcome = rescue_and_log(target: @video) { asking.call }
        render_data(outcome.stitch.as_request, status: outcome.created? ? :created : :ok)
      rescue MusicVideos::RequestStitch::Refused => e
        render_error(e.message, status: :conflict, error_code: "NOT_READY")
      end

      # requested -> running. force: true also restarts a run that died.
      def start
        transition { @stitch.start!(force: ActiveModel::Type::Boolean.new.cast(params[:force]) || false) }
      end

      # running -> done, with the stitcher's measurements. The MP4 is already in R2.
      def finish
        report = params.to_unsafe_h.slice("duration_ms", "byte_size", "width", "height", "frame_rate", "warnings")
        unless report["duration_ms"].is_a?(Integer) && report["duration_ms"].positive? &&
               report["byte_size"].is_a?(Integer) && report["byte_size"].positive?
          return render_error("duration_ms and byte_size above zero are required", error_code: "INVALID_REPORT")
        end

        transition { @stitch.finish!(report) }
      end

      # requested or running -> failed, with the reason.
      def failed
        transition { @stitch.fail!(params[:reason]) }
      end

      private

      def transition
        rescue_and_log(target: @video) do
          yield
        rescue VideoStitch::WrongState => e
          return render_error(e.message, status: :conflict, error_code: "WRONG_STATE")
        end
        render_data(@stitch.as_request)
      end

      def set_video
        @video = MusicVideo.find_by!(slug: params[:music_video_slug])
        @alt_video = @video.alt_videos.includes(:stitches, clips: :versions).find_by!(number: params[:alt_video_number])
        @alt_video.association(:music_video).target = @video
      end

      def set_stitch
        @stitch = @alt_video.stitches.find { |s| s.number == params[:number].to_i } || raise(ActiveRecord::RecordNotFound)
        @stitch.association(:alt_video).target = @alt_video
      end
    end
  end
end
