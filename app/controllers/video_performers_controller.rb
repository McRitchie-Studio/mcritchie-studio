# frozen_string_literal: true

# The operator's answer for one performer on the cast panel: an artist, a
# person from People, a new artist, an extra, or clear.
class VideoPerformersController < ApplicationController
  before_action :require_admin
  before_action :set_performer

  def update
    refusal = refusal_for(resolution)
    return back(alert: "#{@performer.name} not updated: #{refusal}.") if refusal

    rescue_and_log(target: @video) { MusicVideos::ResolvePerformer.new(@performer).call(**resolution) }
    back(notice: notice_for(@performer.reload))
  rescue MusicVideos::ResolvePerformer::Refused, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    back(alert: "#{@performer.name} not updated: #{e.message}")
  end

  private

  def set_performer
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
    @performer = @video.video_performers.find_by!(ordinal: params[:ordinal])
  end

  def resolution
    @resolution ||= begin
      p = params.permit(:artist_slug, :person_slug, :new_artist_name, :new_artist_kind, :extra, :clear)
      { artist_slug: p[:artist_slug].presence, person_slug: p[:person_slug].presence,
        new_artist_name: p[:new_artist_name].presence, new_artist_kind: p[:new_artist_kind].presence,
        extra: p[:extra] == "1", clear: p[:clear] == "1" }
    end
  end

  def refusal_for(r)
    return if r[:extra] || r[:clear] || r[:artist_slug] || r[:person_slug] || r[:new_artist_name]

    "choose an artist or person, or name a new artist"
  end

  def back(**flash)
    redirect_to music_video_path(@video, anchor: "person-#{@performer.ordinal}"), **flash
  end

  def notice_for(performer)
    return "#{performer.name} is an extra." if performer.extra?
    return "#{performer.name} is #{performer.artist.name}." if performer.artist

    "#{performer.name} cleared."
  end
end
