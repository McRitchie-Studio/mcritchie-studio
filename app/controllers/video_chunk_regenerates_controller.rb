# frozen_string_literal: true

# "Request regenerate" on one chunk: a flag with an optional short note that
# says the current take will not do. The next uploaded take clears it
# (MusicVideos::StoreTake); the operator can also clear it by hand.
class VideoChunkRegeneratesController < ApplicationController
  include VideoChunkScoped

  def create
    note = params[:note].to_s.squish
    if note.length > VideoClip::REGENERATE_NOTE_MAX
      return back(alert: "#{@chunk.name} not flagged: keep the note under #{VideoClip::REGENERATE_NOTE_MAX} characters.")
    end

    rescue_and_log(target: @video) { @chunk.request_regenerate!(note) }
    back(notice: "#{@chunk.name} flagged for a regenerate.")
  end

  def destroy
    rescue_and_log(target: @video) { @chunk.clear_regenerate! }
    back(notice: "#{@chunk.name}: regenerate request cleared.")
  end
end
