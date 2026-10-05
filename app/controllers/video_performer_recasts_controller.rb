# frozen_string_literal: true

# The operator's recast for one performer on the cast panel: an athlete and one
# of their looks, keep as is, or clear. Allowed after the cast is confirmed too;
# the video's stored prompts follow (MusicVideos::RecastPerformer).
class VideoPerformerRecastsController < ApplicationController
  before_action :require_admin
  before_action :set_performer

  def update
    choice = recast
    # A refusal is an answer, not an ErrorLog.
    unless choice[:clear] || choice[:keep] || choice[:person_slug]
      return back(alert: "#{@performer.name} not recast: choose an athlete and one of their looks, or keep as is.")
    end

    rescue_and_log(target: @video) { MusicVideos::RecastPerformer.new(@performer).call(**choice) }
    back(notice: notice_for(@performer.reload))
  rescue MusicVideos::RecastPerformer::Refused, ActiveRecord::RecordInvalid => e
    back(alert: "#{@performer.name} not recast: #{e.message}")
  end

  private

  def set_performer
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
    @performer = @video.video_performers.find_by!(ordinal: params[:performer_ordinal])
  end

  def recast
    p = params.permit(:person_slug, :appearance_slug, :keep, :clear)
    { person_slug: p[:person_slug].presence, appearance_slug: p[:appearance_slug].presence,
      keep: p[:keep] == "1", clear: p[:clear] == "1" }
  end

  def back(**flash)
    redirect_to music_video_path(@video, anchor: "person-#{@performer.ordinal}"), **flash
  end

  def notice_for(performer)
    return "#{performer.name} is kept as is." if performer.recast_keep?
    return "#{performer.name} is replaced by #{performer.recast_label}." if performer.recast?
    return "#{performer.recast_label} has no look yet: create one to finish this recast." if performer.recast_pending?

    "#{performer.name}: recast cleared."
  end
end
