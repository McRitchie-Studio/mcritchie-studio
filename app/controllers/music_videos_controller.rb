# frozen_string_literal: true

# /music_videos/:slug — the cast panel (music video pipeline, stage 2). Admin
# only: stills are private objects shown through short-lived signed URLs.
class MusicVideosController < ApplicationController
  before_action :require_admin
  before_action :set_video

  STILL_URL_TTL = 15.minutes.to_i

  def show
    @credits = @video.music_video_artists.includes(:artist).sort_by { |c| [c.role == "primary" ? 0 : 1, c.position] }
    @performers = @video.video_performers.includes(:artist).to_a
    @still_urls = still_urls(@performers.flat_map(&:still_object_keys))
  end

  def confirm_cast
    # A refusal is an answer, not an ErrorLog; confirm_cast! re-checks under a lock.
    return redirect_to music_video_path(@video), alert: "Not yet: #{@video.cast_blocker}." unless @video.cast_ready?

    rescue_and_log(target: @video) { @video.confirm_cast! }
    redirect_to music_video_path(@video), notice: "Cast confirmed."
  rescue MusicVideo::CastNotReady => e
    redirect_to music_video_path(@video), alert: "Not yet: #{e.message}."
  end

  private

  def set_video
    @video = MusicVideo.find_by!(slug: params[:slug])
  end

  # key => signed URL, or nil when the store is not reachable (the card says so).
  def still_urls(keys)
    keys.index_with { |key| AssetBrowser.source.signed_url(key: key, expires_in: STILL_URL_TTL) }
  rescue AssetBrowser::Unavailable
    {}
  end
end
