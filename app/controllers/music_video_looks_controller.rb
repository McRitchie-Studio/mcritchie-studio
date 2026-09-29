# frozen_string_literal: true

# Per-video looks on /music_videos/:slug (pipeline stage 4): make a look for a
# labelled performer, and build its character sheet. Admin only. The sheet
# SPENDS MONEY, so it runs only when the operator presses the button.
class MusicVideoLooksController < ApplicationController
  before_action :require_admin
  before_action :set_video

  def create
    performer = @video.video_performers.find_by!(ordinal: params[:ordinal])
    maker = MusicVideos::CreateLook.new(performer)
    return back(alert: "No look made: #{maker.refusal}.") if maker.refusal

    look = rescue_and_log(target: @video) { maker.call }
    back(notice: "Look made for #{performer.artist.name}.", look: look)
  rescue MusicVideos::CreateLook::Refused, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    back(alert: "No look made: #{e.message}.")
  end

  def sheet
    look = @video.looks.live.find_by!(slug: params[:look_slug])
    return back(alert: "Not yet: the cast is not confirmed.", look: look) unless @video.cast_confirmed?

    artifact = rescue_and_log(target: look) { Appearances::GenerateArtifact.call(look) }
    back(notice: sheet_message(artifact), look: look)
  rescue Appearances::GenerateArtifact::NoGenerator, Appearances::GenerateArtifact::NoIdentityPhoto => e
    back(alert: e.message, look: look)
  rescue StandardError => e
    raise if e.is_a?(ActiveRecord::RecordNotFound)

    back(alert: "Could not build the sheet: #{e.message}", look: look)
  end

  private

  def set_video
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
  end

  def back(look: nil, **flash)
    redirect_to music_video_path(@video, anchor: look ? "look-#{look.slug}" : "looks"), **flash
  end

  def sheet_message(artifact)
    parts = ["#{artifact.generator_label} built one character sheet"]
    parts << artifact.billing_summary if artifact.billing_summary.present?
    "#{parts.join(' · ')}."
  end
end
