# frozen_string_literal: true

# The final stitch of an alt video (recast pipeline, pieces 4 and 13), from
# its page. "Generate full video" records a request. Where this hub has ffmpeg
# (a local one) a job runs it at once; a production dyno has none, so the
# request waits for bin/stitch-video on the Mac. Admin only, like the page.
class AltVideoStitchesController < ApplicationController
  include AltVideoScoped

  def create
    asking = MusicVideos::RequestStitch.new(@alt_video)
    asking.check! # a refusal is an answer, not an ErrorLog
    outcome = rescue_and_log(target: @video) { asking.call }
    stitch = outcome.stitch
    return back(notice: "#{stitch.name} is already #{stitch.running? ? 'running' : 'waiting'}.") unless outcome.created?

    if MusicVideos::Stitcher.available?
      StitchVideoJob.perform_later(@alt_video.slug, stitch.number)
      back(notice: "#{stitch.name} requested: stitching now.")
    else
      back(notice: "#{stitch.name} requested: waiting for bin/stitch-video #{@video.slug} --alt #{@alt_video.number} on the Mac.")
    end
  rescue MusicVideos::RequestStitch::Refused => e
    back(alert: "Not ready to stitch: #{e.message}.")
  end

  # The progress poll: the state alone.
  def show
    stitch = @alt_video.stitches.find_by!(number: params[:number])
    render json: { number: stitch.number, state: stitch.state }
  end

  private

  def back(**flash) = super(anchor: "full-video", **flash)
end
