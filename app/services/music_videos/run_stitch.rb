require "tmpdir"

module MusicVideos
  # Runs one requested stitch on this machine and records how it ended: the
  # hub-side wrapper around MusicVideos::Stitcher (bin/stitch-video is the
  # Mac-side one, reporting through the API instead). Only where ffmpeg is on
  # PATH (Stitcher.available?); StitchVideoJob calls it off the request.
  #
  # Any failure lands on the record as its reason. A request that is no longer
  # waiting (superseded, or already picked up by the bin) is left alone.
  class RunStitch
    def initialize(stitch, store: StitchStorage.new, stitcher: self.class.stitcher)
      @stitch = stitch
      @store = store
      @stitcher = stitcher
    end

    # The one seam to ffmpeg, so the e2e lane (no ffmpeg, no bucket) can stand
    # in for it. The stitcher's progress lines are not kept.
    def self.stitcher = Stitcher.new(out: StringIO.new)

    def call
      begin
        @stitch.start!
      rescue VideoStitch::WrongState
        return @stitch
      end
      Dir.mktmpdir("stitch-#{@stitch.music_video_slug}") do |dir|
        result = @stitcher.call(@stitch.as_request, store: @store, dir:)
        @stitch.finish!(result.report)
      end
      @stitch
    rescue VideoStitch::WrongState
      @stitch # superseded while it ran: the newer request owns the page now
    rescue StandardError => e
      reason = e.is_a?(Stitcher::Failure) ? e.message : "#{e.class.name.demodulize}: #{e.message}"
      @stitch.reload
      @stitch.fail!(reason) if @stitch.open?
      ErrorLog.capture!(e) unless e.is_a?(Stitcher::Failure)
      @stitch
    end
  end
end
