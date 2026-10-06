# frozen_string_literal: true

# The operator's recast for one performer on the cast panel: an athlete and one
# of their looks (or the athlete alone while they have no look); `keep=1` turns
# the swap off and remembers them; `swap=1` turns it back on with what is
# remembered; `clear=1` forgets. Allowed after the cast is confirmed too; the
# video's stored prompts follow (MusicVideos::RecastPerformer).
#
# The cast card saves every pick at once through the JSON variant (Accept:
# application/json): 200 with the saved recast, 422 with the refusal. The HTML
# variant redirects back to the card, as before.
class VideoPerformerRecastsController < ApplicationController
  before_action :require_admin
  before_action :set_performer

  def update
    choice = recast
    # A refusal is an answer, not an ErrorLog.
    unless choice[:clear] || choice[:keep] || choice[:swap] || (choice[:person_slug] && (choice[:appearance_slug] || lookless?(choice[:person_slug])))
      return refuse("choose an athlete and one of their looks, or turn the swap off.")
    end

    rescue_and_log(target: @video) { MusicVideos::RecastPerformer.new(@performer).call(**choice) }
    @performer.reload
    return render(json: saved_json) if json?

    back(notice: notice_for(@performer))
  rescue MusicVideos::RecastPerformer::Refused, ActiveRecord::RecordInvalid => e
    refuse(e.message)
  end

  private

  def set_performer
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
    @performer = @video.video_performers.find_by!(ordinal: params[:performer_ordinal])
  end

  def json? = request.format.json?

  def recast
    p = params.permit(:person_slug, :appearance_slug, :keep, :swap, :clear)
    { person_slug: p[:person_slug].presence, appearance_slug: p[:appearance_slug].presence,
      keep: p[:keep].to_s == "1", swap: p[:swap].to_s == "1", clear: p[:clear].to_s == "1" }
  end

  # An athlete with no look yet is saved alone; the card then offers to create one.
  def lookless?(person_slug) = !Appearance.recastable.exists?(person_slug:)

  def refuse(reason)
    return render(json: { error: "#{@performer.name} not recast: #{reason}" }, status: 422) if json?

    back(alert: "#{@performer.name} not recast: #{reason}")
  end

  # What the card shows once the server has the pick: the stored athlete and
  # look (remembered while off), and the state the card reads (off, pending, recast).
  def saved_json
    state = if @performer.recast? then "recast" elsif @performer.recast_pending? then "pending" else "off" end
    { state:, person_slug: @performer.recast_person_slug, appearance_slug: @performer.recast_appearance_slug,
      label: @performer.recast_label, message: notice_for(@performer) }
  end

  def back(**flash)
    redirect_to music_video_path(@video, anchor: "person-#{@performer.ordinal}"), **flash
  end

  def notice_for(performer)
    return "#{performer.name} is replaced by #{performer.recast_label}." if performer.recast?
    return "#{performer.recast_label} has no look yet: create one to finish this recast." if performer.recast_pending?
    return "#{performer.name} is not swapped; #{performer.recast_label} is remembered." if performer.swap_remembered?

    "#{performer.name} is not swapped."
  end
end
