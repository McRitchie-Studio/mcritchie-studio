module Api
  module V1
    # The final stitch as bin/stitch-video drives it (recast pipeline, piece 4).
    # The Mac has ffmpeg and the dyno does not, so the bin reads the waiting
    # request here, stitches, uploads the MP4 to R2 itself, and reports back.
    # Each stitch is served as the stitcher's request: its takes resolved to
    # their objects, the source key, and where the result goes.
    class MusicVideoStitchesController < BaseController
      before_action :set_video
      before_action :set_stitch, only: %i[start finish failed]

      # Every stitch, newest first, and whether a new one may be requested.
      def index
        render_data({ "stitches" => @video.stitches.reverse.map(&:as_request),
                      "ready" => @video.ready_to_stitch?, "blocker" => @video.stitch_blocker,
                      "current_takes" => VideoStitch.takes_of(@video.video_chunks) })
      end

      # Open a request from the current takes, or hand back the one already
      # open for them. 201 when this call opened it.
      def create
        asking = MusicVideos::RequestStitch.new(@video)
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
      end

      def set_stitch
        @stitch = @video.stitches.find_by!(number: params[:number])
      end
    end
  end
end
