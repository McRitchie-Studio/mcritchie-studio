# frozen_string_literal: true

# The alt video asset zips (recast pipeline, piece 17), streamed:
#
#   GET /music_videos/:slug/alt_videos/:number/download                  every clip
#   GET /music_videos/:slug/alt_videos/:number/clips/:ordinal/download   one clip
#
# Admin only, like the page: the zip carries private R2 objects. Every row is
# read before the response starts (MusicVideos::AssetZip::Manifest); the body
# then only streams bytes from R2 and the sheet hosts, so the first byte leaves
# at once and the dyno never holds a file whole. See MusicVideos::AssetZip.
class AltVideoDownloadsController < ApplicationController
  include ZipKit::RailsStreaming

  before_action :require_admin

  def show
    video = MusicVideo.find_by!(slug: params[:music_video_slug])
    alt = video.alt_videos.find_by!(number: params[:alt_video_number])
    alt.association(:music_video).target = video
    manifest = MusicVideos::AssetZip::Manifest.for(alt, only: params[:clip_ordinal],
                                                         page_url: music_video_alt_video_url(video, alt))
    # A private download, never cached. (Rack::Deflater skips a zip: config/application.rb.)
    response.headers["Cache-Control"] = "private, no-store"
    zip_kit_stream(filename: manifest.filename) do |zip|
      result = MusicVideos::AssetZip::Writer.new(manifest).write(zip)
      Rails.logger.info("[asset_zip] #{manifest.filename}: #{result.written} files, #{result.missing.size} not included")
    end
  end
end
