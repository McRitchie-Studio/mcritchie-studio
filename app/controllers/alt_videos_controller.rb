# frozen_string_literal: true

# Alt videos (recast pipeline, piece 13): each generated version of a source
# video, with its own swaps snapshotted from the cast card.
#
#   GET  /alt_videos                              every alt video, with progress
#   POST /music_videos/:slug/alt_videos           Build Clips: the next alt video
#   GET  /music_videos/:slug/alt_videos/:number   its clip builder
#   GET  /music_videos/:slug/alt_videos/:number/links   fresh signed URLs for that page (JSON)
#
# Admin only: chunks, versions and stitches are private objects shown through
# short-lived signed URLs. The page outlives them (it stays open while the
# operator works elsewhere), so it asks `links` for fresh ones.
class AltVideosController < ApplicationController
  before_action :require_admin
  before_action :set_video, only: %i[create show links]

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
    load_alt_video(clips: %i[versions tiktok_drafts])
    @swaps = @alt_video.swap_set
    # Loaded ON the association, so every clip's target reads the same rows.
    @performers = @video.video_performers.to_a
    ActiveRecord::Associations::Preloader.new(records: @performers, associations: :artist).call
    sign_files
    @sheets = Artifact.newest_character_sheets(@swaps.appearance_slugs)
    @numbers = MusicVideos::ClipPrompts.numbers_for(@swaps)
    @watch = helpers.alt_watch_data(@clips, @chunk_for, @urls)
    @stitch_here = MusicVideos::Stitcher.available?
  end

  # The page's signed URLs again, by object key: `inline` plays or shows a file,
  # `download` saves it. It signs the key set `show` builds and nothing else: it
  # reads no key from the request. The page asks with Accept: application/json,
  # so AdminWall answers a signed-out fetch 401 and a non-admin 403, not a redirect.
  def links
    load_alt_video(clips: :versions)
    sign_files
    inline = @urls.merge(@stitch_urls).select { |key, url| key.present? && url.present? }
    download = @downloads.merge(@stitch_downloads).select { |key, url| key.present? && url.present? }
    response.headers["Cache-Control"] = "no-store"
    return render json: { error: "storage_unreachable" }, status: :service_unavailable if inline.empty?

    render json: { ttl: SIGNED_URL_TTL, signed_at: (@signed_at.to_f * 1000).round,
                   expires_at: (@signed_at + SIGNED_URL_TTL).iso8601, inline:, download: }
  end

  private

  # The alt video with its stitches, its clips and each clip's source chunk.
  def load_alt_video(clips:)
    @alt_video = @video.alt_videos.includes(:stitches, clips:).find_by!(number: params[:number])
    @alt_video.association(:music_video).target = @video
    @chunks = @video.video_chunks.to_a
    @chunks.each { |chunk| chunk.association(:music_video).target = @video }
    @clips = @alt_video.clips.to_a
    @clips.each { |clip| clip.association(:alt_video).target = @alt_video }
    @chunk_for = @clips.to_h { |clip| [clip.chunk_ordinal, clip.chunk_in(@chunks)] }
    @stitches = @alt_video.stitches.to_a.reverse
    @stitches.each { |stitch| stitch.association(:alt_video).target = @alt_video }
  end

  # The signed files the page plays and downloads, by object key: each clip's
  # source chunk and its lettered reference frames, every version, the source
  # audio, and every finished stitch. @signed_at is when they were signed, which
  # with SIGNED_URL_TTL tells the page when they lapse.
  def sign_files
    @signed_at = Time.current
    chunks = @chunk_for.values.compact
    chunk_keys = chunks.map(&:object_key)
    frame_keys = chunks.flat_map { |chunk| chunk.reference_frame_list.map { |f| f["object_key"] } }
    version_keys = @clips.flat_map { |clip| clip.versions.map(&:object_key) }
    stitch_keys = @stitches.select(&:done?).map(&:object_key)
    @urls = signed_urls(chunk_keys + frame_keys + version_keys + [@video.source_object_key])
    @downloads = signed_urls(chunk_keys + frame_keys, download: true)
    @stitch_urls = signed_urls(stitch_keys)
    @stitch_downloads = signed_urls(stitch_keys, download: true)
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
