# frozen_string_literal: true

# The operator's answer for one performer on the cast panel: an artist, a
# person from People, a new artist, an extra, or clear. Naming is optional.
#
# The cast card's always-visible "Who is this on screen?" search saves each
# pick at once through the JSON variant (Accept: application/json): 200 with
# what the card shows (MusicVideos::CastCardNaming), 422 with the refusal. The
# HTML variant redirects back to the card, as before.
class VideoPerformersController < ApplicationController
  before_action :require_admin
  before_action :set_performer

  def update
    refusal = refusal_for(resolution)
    return refuse("#{refusal}.") if refusal

    rescue_and_log(target: @video) { MusicVideos::ResolvePerformer.new(@performer).call(**resolution) }
    @performer.reload
    return render(json: saved_json) if json?

    back(notice: notice_for(@performer))
  rescue MusicVideos::ResolvePerformer::Refused, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    refuse(e.message)
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

  def json? = request.format.json?

  def refuse(reason)
    return render(json: { error: "#{@performer.name} not updated: #{reason}" }, status: 422) if json?

    back(alert: "#{@performer.name} not updated: #{reason}")
  end

  def saved_json
    { named: MusicVideos::CastCardNaming.state(@performer), offer: MusicVideos::CastCardNaming.offer(@performer),
      message: notice_for(@performer) }
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
