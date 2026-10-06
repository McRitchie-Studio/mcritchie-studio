# frozen_string_literal: true

# /music_videos/:slug — the cast panel (music video pipeline, stage 2) with
# each performer's recast, the
# clip candidates (stage 5) and the chunks the whole video is tiled into, with
# each chunk's hand-off, generated takes, the stitch preview and the final
# stitched video. Admin only:
# stills, clips and takes are private objects shown through short-lived signed URLs.
class MusicVideosController < ApplicationController
  before_action :require_admin
  before_action :set_video

  SIGNED_URL_TTL = 15.minutes.to_i

  def show
    @credits = @video.music_video_artists.includes(:artist).sort_by { |c| [c.role == "primary" ? 0 : 1, c.position] }
    # Loaded ON the association, so each clip's swap target reads the same rows.
    @performers = @video.video_performers.to_a
    ActiveRecord::Associations::Preloader.new(records: @performers,
                                              associations: [{ artist: :person }, :recast_person, :recast_appearance]).call
    # Each recast athlete's look dropdown rows: thumbnail, default mark, build state.
    # The recast athletes, and the people the cards are named after (the named
    # block's headshot, and the "Swap with <name>?" offer when they have looks).
    people = (@performers.filter_map(&:recast_person_slug) + @performers.filter_map { |p| p.artist&.person_slug }).uniq
    @recast_looks = MusicVideos::LookOptions.for(people)
    # Each person's block on the card: headshot, vocation, team.
    @recast_rows = People::SearchRows.for(people)
    @still_urls = signed_urls(@performers.flat_map(&:still_object_keys))
    @clips = @video.clip_candidates.to_a
    @chunks = @video.video_chunks.to_a
    # Each row reads its swap target off THIS video's loaded cast, not a copy per row.
    (@clips + @chunks).each { |clip| clip.association(:music_video).target = @video }
    load_looks
    load_chunk_review
    load_stitches
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
    @look_sheets = Artifact.newest_character_sheets(@looks.map(&:slug))
    @sheet_row = Appearances::GenerateArtifact.preferred_row
    @sheet_ready = Appearances::GenerateArtifact.available?
  end

  # The recast round trip: each chunk's takes (one query, read off the video),
  # the signed files the page plays and downloads, the recast looks' character
  # sheets for the hand-off, and the stitch preview's timeline.
  def load_chunk_review
    @video.chunk_takes.load
    take_keys = @chunks.flat_map { |chunk| chunk.takes.map(&:object_key) }
    @clip_urls = signed_urls((@clips + @chunks).map(&:object_key) + take_keys + [@video.source_object_key])
    @chunk_downloads = signed_urls(@chunks.map(&:object_key), download: true)
    @recast_sheets = Artifact.newest_character_sheets(@performers.filter_map(&:recast_appearance_slug))
    @stitch = helpers.stitch_preview_data(@chunks, @clip_urls)
  end

  # The final stitch: every stitch of the video, newest first, the signed
  # files of the finished ones, and whether this hub can stitch on its own.
  def load_stitches
    @stitches = @video.stitches.to_a.reverse
    @stitches.each { |stitch| stitch.association(:music_video).target = @video }
    keys = @stitches.select(&:done?).map(&:object_key)
    @stitch_urls = signed_urls(keys)
    @stitch_downloads = signed_urls(keys, download: true)
    @stitch_here = MusicVideos::Stitcher.available?
  end

  def set_video
    @video = MusicVideo.find_by!(slug: params[:slug])
  end

  # key => signed URL, or nil when the store is not reachable (the card says so).
  # download: the URL answers as an attachment named after the object.
  def signed_urls(keys, download: false)
    keys.uniq.index_with do |key|
      AssetBrowser.source.signed_url(key: key, expires_in: SIGNED_URL_TTL, **(download ? { download_as: File.basename(key) } : {}))
    end
  rescue AssetBrowser::Unavailable
    {}
  end
end
