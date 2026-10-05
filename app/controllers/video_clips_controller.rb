# frozen_string_literal: true

# The operator's answer on one clip candidate: approve or reject. The video is
# clips_ready while at least one candidate is approved. Chunks have no decision.
class VideoClipsController < ApplicationController
  before_action :require_admin
  before_action :set_clip

  DECISIONS = %w[approved rejected proposed].freeze

  def update
    status = params[:status].to_s
    return back(alert: "#{@clip.name} not updated: choose approve or reject.") unless DECISIONS.include?(status)

    rescue_and_log(target: @video) do
      VideoClip.transaction do
        @video.lock!
        @clip.update!(status:)
        @video.sync_clip_stage!
      end
    end
    back(notice: "#{@clip.name} #{status == 'proposed' ? 'reopened' : status}.")
  end

  private

  def set_clip
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
    @clip = @video.clip_candidates.find_by!(ordinal: params[:ordinal])
  end

  def back(**flash)
    redirect_to music_video_path(@video, anchor: "clip-#{@clip.ordinal}"), **flash
  end
end
