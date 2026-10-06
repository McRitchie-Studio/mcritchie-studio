# frozen_string_literal: true

# Alt videos (recast pipeline, piece 13): each generated version of a source
# video, with its own swaps snapshotted from the cast card.
#
#   GET  /alt_videos                              every alt video, with progress
#   POST /music_videos/:slug/alt_videos           Build Clips: the next alt video
#   GET  /music_videos/:slug/alt_videos/:number   its clip builder
#
# Admin only: chunks, versions and stitches are private objects shown through
# short-lived signed URLs.
class AltVideosController < ApplicationController
  before_action :require_admin
  before_action :set_video, only: %i[create show]

  SIGNED_URL_TTL = MusicVideosController::SIGNED_URL_TTL

  def index
    @alt_videos = AltVideo.includes(:music_video, :stitches, clips: :versions)
                          .order(created_at: :desc, id: :desc).to_a
                          .sort_by { |alt| -alt.last_activity_at.to_f }
  end

  def create
    alt = rescue_and_log(target: @video) { AltVideo.build_from!(@video) }
    redirect_to music_video_alt_video_path(@video, alt), status: :see_other,
                notice: "#{alt.name} built: #{alt.clips.size} clips, #{alt.swaps_summary}."
  rescue AltVideo::NotReady => e
    redirect_to music_video_path(@video), alert: "Not yet: #{e.message}.", status: :see_other
  end

  def show
    @alt_video = @video.alt_videos.includes(:stitches, clips: :versions).find_by!(number: params[:number])
    @alt_video.association(:music_video).target = @video
    @swaps = @alt_video.swap_set
    # Loaded ON the association, so every clip's target reads the same rows.
    @performers = @video.video_performers.to_a
    ActiveRecord::Associations::Preloader.new(records: @performers, associations: :artist).call
    @chunks = @video.video_chunks.to_a
    @chunks.each { |chunk| chunk.association(:music_video).target = @video }
    @clips = @alt_video.clips.to_a
    @clips.each { |clip| clip.association(:alt_video).target = @alt_video }
    @chunk_for = @clips.to_h { |clip| [clip.chunk_ordinal, clip.chunk_in(@chunks)] }
    load_files
    load_stitches
  end

  private

  # The signed files the page plays and downloads: each clip's source chunk,
  # every version, the source audio, and the swapped people's character sheets.
  def load_files
    chunk_keys = @chunk_for.values.compact.map(&:object_key)
    version_keys = @clips.flat_map { |clip| clip.versions.map(&:object_key) }
    @urls = signed_urls(chunk_keys + version_keys + [@video.source_object_key])
    @downloads = signed_urls(chunk_keys, download: true)
    @sheets = Artifact.newest_character_sheets(@swaps.appearance_slugs)
    @watch = helpers.alt_watch_data(@clips, @chunk_for, @urls)
  end

  def load_stitches
    @stitches = @alt_video.stitches.to_a.reverse
    @stitches.each { |stitch| stitch.association(:alt_video).target = @alt_video }
    keys = @stitches.select(&:done?).map(&:object_key)
    @stitch_urls = signed_urls(keys)
    @stitch_downloads = signed_urls(keys, download: true)
    @stitch_here = MusicVideos::Stitcher.available?
  end

  def set_video
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
  end

  # key => signed URL, or nil when the store is not reachable (the card says so).
  def signed_urls(keys, download: false)
    keys.uniq.index_with do |key|
      AssetBrowser.source.signed_url(key: key, expires_in: SIGNED_URL_TTL, **(download ? { download_as: File.basename(key) } : {}))
    end
  rescue AssetBrowser::Unavailable
    {}
  end
end
