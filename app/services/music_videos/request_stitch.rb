module MusicVideos
  # Records a request for an alt video's full stitched video: stitch N of the
  # alt video, from the primary version every clip has right now. Pressing
  # "Generate full video" and bin/stitch-video both come through here.
  #
  # One open request at a time. Asking again while the same versions are
  # already waiting or running hands that request back; asking with different
  # versions, or after a run has gone quiet for VideoStitch::RUN_TIMEOUT,
  # closes the old one as superseded and opens the next number. Nothing is
  # ever overwritten.
  class RequestStitch
    class Refused < StandardError; end

    Outcome = Data.define(:stitch, :created) do
      def created? = created
    end

    def initialize(alt_video)
      @alt = alt_video
    end

    # Raises Refused with the blocker when the alt video is not ready to stitch.
    def check!
      raise Refused, @alt.stitch_blocker || "the alt video is not ready to stitch" unless @alt.ready_to_stitch?
    end

    def call
      VideoStitch.transaction do
        @alt.lock!
        @alt.clips.reset
        @alt.stitches.reset
        check!
        takes = VideoStitch.takes_of(@alt.clips)
        open = @alt.stitches.select(&:open?)
        same = open.find { |s| s.takes == takes && !s.stuck? }
        next Outcome.new(stitch: same, created: false) if same

        number = @alt.stitches.maximum(:number).to_i + 1
        open.each { |s| s.fail!("superseded by stitch #{number}") }
        stitch = @alt.stitches.create!(
          number:, state: "requested", takes:, music_video_slug: @alt.music_video_slug,
          object_key: ObjectKeys.alt_stitched(source_key: @alt.music_video.source_object_key, alt_number: @alt.number, number:)
        )
        Outcome.new(stitch:, created: true)
      end
    end
  end
end
