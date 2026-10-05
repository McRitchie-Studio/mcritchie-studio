# frozen_string_literal: true

# The generated takes of one chunk (recast pipeline, piece 3): the operator
# uploads the MP4 the hand swap produced, and may put an older take back in
# front. Takes are kept, never overwritten or deleted here.
class VideoChunkTakesController < ApplicationController
  include VideoChunkScoped

  def create
    store = MusicVideos::StoreTake.new(@chunk, params[:file])
    store.validate! # a refusal is an answer, not an ErrorLog
    take = rescue_and_log(target: @video) { store.call }
    back(notice: "#{@chunk.name}: #{take.name.downcase} uploaded and current.")
  rescue MusicVideos::StoreTake::Refused => e
    back(alert: "#{@chunk.name} take not uploaded: #{e.message}.")
  rescue MusicVideos::StoreTake::StorageFailed => e
    back(alert: "#{@chunk.name} take not uploaded: #{e.message}. Nothing was recorded; try again.")
  end

  def current
    take = @chunk.takes.find { |t| t.number == params[:number].to_i } || raise(ActiveRecord::RecordNotFound)
    rescue_and_log(target: @video) { take.make_current! }
    back(notice: "#{@chunk.name}: #{take.name.downcase} is current.")
  end
end
