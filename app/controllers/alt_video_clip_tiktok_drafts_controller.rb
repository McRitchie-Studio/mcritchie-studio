# frozen_string_literal: true

# "Draft to TikTok" on one clip of an alt video (recast pipeline, piece 19):
# records an attempt with the caption the code wrote and queues the upload of
# the clip's primary version into the operator's TikTok drafts. "Check TikTok"
# reads TikTok's status once more for an attempt still processing.
#
#   POST /music_videos/:slug/alt_videos/:n/clips/:ordinal/tiktok_drafts
#   POST /music_videos/:slug/alt_videos/:n/clips/:ordinal/tiktok_drafts/:id/refresh
#
# The same machine as bin/tiktok-draft (Api::V1::TiktokDraftsController).
class AltVideoClipTiktokDraftsController < ApplicationController
  include AltVideoScoped

  before_action :set_clip

  def create
    service = Tiktok::DraftClip.new
    preview = service.check!(@clip) # a refusal is an answer, not an ErrorLog
    draft = rescue_and_log(target: @video) { service.record!(preview, by: current_user&.email) }
    back(notice: "#{@clip.name} is on its way to your TikTok drafts (attempt #{draft.id}). Paste the caption when you post.")
  rescue Tiktok::DraftClip::Refused => e
    back(alert: "#{@clip.name} not drafted: #{e.message}.")
  end

  def refresh
    draft = @clip.tiktok_drafts.find(params[:id])
    rescue_and_log(target: @video) { Tiktok::DraftClip.new.refresh(draft) }
    back(notice: "#{@clip.name}, attempt #{draft.id}: #{draft.state_label}.")
  end
end
