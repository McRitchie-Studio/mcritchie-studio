# frozen_string_literal: true

# One chunk of a tiled video, addressed as /music_videos/:slug/chunks/:ordinal.
# Admin only, like the page. Clip candidates are never reachable here.
module VideoChunkScoped
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    before_action :set_chunk
  end

  private

  def set_chunk
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
    @chunk = @video.video_chunks.find_by!(ordinal: params[:chunk_ordinal])
  end

  def back(**flash)
    redirect_to music_video_path(@video, anchor: "chunk-#{@chunk.ordinal}"), status: :see_other, **flash
  end
end
