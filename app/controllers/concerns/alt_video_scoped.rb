# frozen_string_literal: true

# One alt video of a source, addressed as /music_videos/:slug/alt_videos/:number,
# and with :clip_ordinal one of its clips. Admin only, like every page of the
# recast pipeline.
module AltVideoScoped
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    before_action :set_alt_video
  end

  private

  def set_alt_video
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
    @alt_video = @video.alt_videos.find_by!(number: params[:alt_video_number])
    @alt_video.association(:music_video).target = @video
  end

  def set_clip
    @clip = @alt_video.clips.find_by!(chunk_ordinal: params[:clip_ordinal])
    @clip.association(:alt_video).target = @alt_video
  end

  def back(anchor: nil, **flash)
    anchor ||= @clip ? "clip-#{@clip.chunk_ordinal}" : nil
    redirect_to music_video_alt_video_path(@video, @alt_video, anchor:), status: :see_other, **flash
  end
end
