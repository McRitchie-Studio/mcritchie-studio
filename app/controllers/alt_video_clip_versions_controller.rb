# frozen_string_literal: true

# The generated versions of one clip of an alt video (recast pipeline, piece
# 13): the operator drops or picks the MP4 the hand swap produced, and may put
# an older version back in front. Versions are kept, never overwritten or
# deleted here.
class AltVideoClipVersionsController < ApplicationController
  include AltVideoScoped

  before_action :set_clip

  def create
    store = MusicVideos::StoreClipVersion.new(@clip, params[:file])
    store.validate! # a refusal is an answer, not an ErrorLog
    version = rescue_and_log(target: @video) { store.call }
    back(notice: "#{@clip.name}: #{version.name.downcase} uploaded and primary.")
  rescue MusicVideos::StoreClipVersion::Refused => e
    back(alert: "#{@clip.name} version not uploaded: #{e.message}.")
  rescue MusicVideos::StoreClipVersion::StorageFailed => e
    back(alert: "#{@clip.name} version not uploaded: #{e.message}. Nothing was recorded; try again.")
  end

  def primary
    version = @clip.versions.find_by!(number: params[:number])
    rescue_and_log(target: @video) { version.make_primary! }
    back(notice: "#{@clip.name}: #{version.name.downcase} is primary.")
  end
end
