module MusicVideos
  # Records a request for the full stitched video: stitch N of the video, from
  # the take every chunk has right now. Pressing "Generate full video" and
  # bin/stitch-video both come through here.
  #
  # One open request at a time. Asking again while the same takes are already
  # waiting or running hands that request back; asking with different takes,
  # or after a run has gone quiet for VideoStitch::RUN_TIMEOUT, closes the old
  # one as superseded and opens the next number. Nothing is ever overwritten.
  class RequestStitch
    class Refused < StandardError; end

    Outcome = Data.define(:stitch, :created) do
      def created? = created
    end

    def initialize(video)
      @video = video
    end

    # Raises Refused with the blocker when the video is not ready to stitch.
    def check!
      raise Refused, @video.stitch_blocker || "the video is not ready to stitch" unless @video.ready_to_stitch?
    end

    def call
      VideoStitch.transaction do
        @video.lock!
        @video.video_chunks.reset
        @video.chunk_takes.reset
        check!
        takes = VideoStitch.takes_of(@video.video_chunks)
        open = @video.stitches.select(&:open?)
        same = open.find { |s| s.takes == takes && !s.stuck? }
        next Outcome.new(stitch: same, created: false) if same

        number = @video.stitches.maximum(:number).to_i + 1
        open.each { |s| s.fail!("superseded by stitch #{number}") }
        stitch = @video.stitches.create!(
          number:, state: "requested", takes:,
          object_key: ObjectKeys.stitched(source_key: @video.source_object_key, number:)
        )
        Outcome.new(stitch:, created: true)
      end
    end
  end
end
