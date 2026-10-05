# frozen_string_literal: true

# The final stitch of a tiled video (recast pipeline, piece 4), from the page.
# "Generate full video" records a request. Where this hub has ffmpeg (a local
# one) a job runs it at once; a production dyno has none, so the request waits
# for bin/stitch-video on the Mac. Admin only, like the page.
class VideoStitchesController < ApplicationController
  before_action :require_admin
  before_action :set_video

  def create
    asking = MusicVideos::RequestStitch.new(@video)
    asking.check! # a refusal is an answer, not an ErrorLog
    outcome = rescue_and_log(target: @video) { asking.call }
    stitch = outcome.stitch
    return back(notice: "#{stitch.name} is already #{stitch.running? ? 'running' : 'waiting'}.") unless outcome.created?

    if MusicVideos::Stitcher.available?
      StitchVideoJob.perform_later(@video.slug, stitch.number)
      back(notice: "#{stitch.name} requested: stitching now.")
    else
      back(notice: "#{stitch.name} requested: waiting for bin/stitch-video #{@video.slug} on the Mac.")
    end
  rescue MusicVideos::RequestStitch::Refused => e
    back(alert: "Not ready to stitch: #{e.message}.")
  end

  # The progress poll: the state alone.
  def show
    stitch = @video.stitches.find_by!(number: params[:number])
    render json: { number: stitch.number, state: stitch.state }
  end

  private

  def set_video
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
  end

  def back(**flash)
    redirect_to music_video_path(@video, anchor: "full-video"), status: :see_other, **flash
  end
end
