# frozen_string_literal: true

# The alt video asset zips (recast pipeline, piece 17), streamed:
#
#   GET /videos/:slug/alt_videos/:number/download                  every clip
#   GET /videos/:slug/alt_videos/:number/clips/:ordinal/download   one clip
#
# Admin only, like the page: the zip carries private R2 objects. Every row is
# read before the response starts (Videos::AssetZip::Manifest); the body
# then only streams bytes from R2 and the sheet hosts, so the first byte leaves
# at once and the dyno never holds a file whole. See Videos::AssetZip.
class AltVideoDownloadsController < ApplicationController
  include ZipKit::RailsStreaming

  before_action :require_admin

  def show
    video = Video.find_by!(slug: params[:video_slug])
    alt = video.alt_videos.find_by!(number: params[:alt_video_number])
    alt.association(:video).target = video
    manifest = Videos::AssetZip::Manifest.for(alt, only: params[:clip_ordinal],
                                                         page_url: video_alt_video_url(video, alt))
    # A private download, never cached. (Rack::Deflater skips a zip: config/application.rb.)
    response.headers["Cache-Control"] = "private, no-store"
    zip_kit_stream(filename: manifest.filename) do |zip|
      result = Videos::AssetZip::Writer.new(manifest).write(zip)
      Rails.logger.info("[asset_zip] #{manifest.filename}: #{result.written} files, #{result.missing.size} not included")
    end
  end
end
