# frozen_string_literal: true

# Runs one requested stitch off the request, on a hub that has ffmpeg
# (MusicVideos::RunStitch). Never retried: RunStitch records a failure on the
# stitch itself, and a second run of a stitch that is no longer waiting does
# nothing. Production dynos have no ffmpeg, so there the request is never
# enqueued and waits for bin/stitch-video.
class StitchVideoJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(music_video_slug, number)
    stitch = VideoStitch.find_by(music_video_slug:, number:)
    MusicVideos::RunStitch.new(stitch).call if stitch
  end
end
