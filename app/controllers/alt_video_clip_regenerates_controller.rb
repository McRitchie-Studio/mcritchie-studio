# frozen_string_literal: true

# "Request regenerate" on one clip of an alt video: a flag with an optional
# short note that says the primary version will not do. The next uploaded
# version clears it (MusicVideos::StoreClipVersion); the operator can also
# clear it by hand. Piece 3's chunk flag, moved onto the clip.
class AltVideoClipRegeneratesController < ApplicationController
  include AltVideoScoped

  before_action :set_clip

  def create
    note = params[:note].to_s.squish
    if note.length > AltVideoClip::REGENERATE_NOTE_MAX
      return back(alert: "#{@clip.name} not flagged: keep the note under #{AltVideoClip::REGENERATE_NOTE_MAX} characters.")
    end

    rescue_and_log(target: @video) { @clip.request_regenerate!(note) }
    back(notice: "#{@clip.name} flagged for a regenerate.")
  end

  def destroy
    rescue_and_log(target: @video) { @clip.clear_regenerate! }
    back(notice: "#{@clip.name}: regenerate request cleared.")
  end
end
