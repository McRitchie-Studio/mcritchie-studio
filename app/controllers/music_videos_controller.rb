# frozen_string_literal: true

# /music_videos/:slug — the cast panel (music video pipeline, stage 2) with
# each performer's recast, the
# clip candidates (stage 5) and the chunks the whole video is tiled into. Admin only: stills and clips are private objects shown
# through short-lived signed URLs.
class MusicVideosController < ApplicationController
  before_action :require_admin
  before_action :set_video

  SIGNED_URL_TTL = 15.minutes.to_i

  def show
    @credits = @video.music_video_artists.includes(:artist).sort_by { |c| [c.role == "primary" ? 0 : 1, c.position] }
    # Loaded ON the association, so each clip's swap target reads the same rows.
    @performers = @video.video_performers.to_a
    ActiveRecord::Associations::Preloader.new(records: @performers,
                                              associations: %i[artist recast_person recast_appearance]).call
    @recast_looks = Appearance.recastable.where(person_slug: @performers.filter_map(&:recast_person_slug))
                              .order(:created_at, :id).group_by(&:person_slug)
    @still_urls = signed_urls(@performers.flat_map(&:still_object_keys))
    @clips = @video.clip_candidates.to_a
    @chunks = @video.video_chunks.to_a
    # Each row reads its swap target off THIS video's loaded cast, not a copy per row.
    (@clips + @chunks).each { |clip| clip.association(:music_video).target = @video }
    load_looks
    @clip_urls = signed_urls((@clips + @chunks).map(&:object_key))
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

  # Stage 4: each live look, the labelled performers still without one, and
  # each look's newest character sheet.
  def load_looks
    @looks = @video.looks.live.includes(:person).order(:performer_ordinal).to_a
    with_look = @looks.map(&:performer_ordinal)
    @look_candidates = @performers.select { |p| p.artist && !p.artist.group? && with_look.exclude?(p.ordinal) }
    @look_sheets = ArtifactSubject.where(appearance_slug: @looks.map(&:slug)).includes(:artifact)
                                  .joins(:artifact).merge(Artifact.live.where(kind: "character_sheet"))
                                  .order("artifacts.created_at DESC")
                                  .each_with_object({}) { |s, h| h[s.appearance_slug] ||= s.artifact }
    @sheet_row = Appearances::GenerateArtifact.preferred_row
    @sheet_ready = Appearances::GenerateArtifact.available?
  end

  def set_video
    @video = MusicVideo.find_by!(slug: params[:slug])
  end

  # key => signed URL, or nil when the store is not reachable (the card says so).
  def signed_urls(keys)
    keys.index_with { |key| AssetBrowser.source.signed_url(key: key, expires_in: SIGNED_URL_TTL) }
  rescue AssetBrowser::Unavailable
    {}
  end
end
