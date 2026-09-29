# frozen_string_literal: true

# Per-video looks on /music_videos/:slug (pipeline stage 4): make a look for a
# labelled performer, and build its character sheet. Admin only. The sheet
# SPENDS MONEY, so it runs only when the operator presses the button, in a job.
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

  # Enqueues the build (Appearances::SheetBuild) and returns at once; the card
  # shows building / done / failed.
  def sheet
    look = @video.looks.live.find_by!(slug: params[:look_slug])
    return back(alert: "Not yet: the cast is not confirmed.", look: look) unless @video.cast_confirmed?

    rescue_and_log(target: look) { start_build(look) }
  rescue StandardError => e
    raise if e.is_a?(ActiveRecord::RecordNotFound)

    back(alert: "Could not start the sheet build: #{e.message}", look: look)
  end

  private

  def set_video
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
  end

  def back(look: nil, **flash)
    redirect_to music_video_path(@video, anchor: look ? "look-#{look.slug}" : "looks"), **flash
  end

  # The refusals and the busy guard are answers, not ErrorLog rows.
  def start_build(look)
    Appearances::SheetBuild.start!(look)
    back(notice: Appearances::SheetBuild::STARTED_NOTICE, look: look)
  rescue Appearances::GenerateArtifact::NoGenerator, Appearances::GenerateArtifact::NoIdentityPhoto,
         Appearances::SheetBuild::Busy => e
    back(alert: e.message, look: look)
  end
end
