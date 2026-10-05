# frozen_string_literal: true

# "Generate a new look" on a cast card: makes a look for the athlete the
# operator chose and starts its character sheet through the one existing build
# (Appearances::SheetBuild, in a job). Admin only: THE SHEET SPENDS MONEY, and
# hub signup is open, so a session alone is no cost control. Nothing here calls
# a generator; the request claims the look, enqueues, and returns.
class VideoPerformerRecastLooksController < ApplicationController
  before_action :require_admin
  before_action :set_performer

  def create
    maker = MusicVideos::CreateRecastLook.new(@performer, **look_params)
    # A refusal is an answer, not an ErrorLog.
    return back(alert: "No look made: #{maker.refusal}.") if maker.refusal

    look = make(maker)
    build(look) if look
  end

  private

  def set_performer
    @video = MusicVideo.find_by!(slug: params[:music_video_slug])
    @performer = @video.video_performers.find_by!(ordinal: params[:performer_ordinal])
  end

  def look_params
    p = params.permit(:person_slug, :descriptor, :reference_url)
    { person_slug: p[:person_slug], descriptor: p[:descriptor], reference_url: p[:reference_url] }
  end

  # look: the card previews the look just made.
  def back(look: nil, **flash)
    redirect_to music_video_path(@video, look: look&.slug, anchor: "person-#{@performer.ordinal}"), **flash
  end

  def make(maker)
    rescue_and_log(target: @video) { maker.call }
  rescue MusicVideos::CreateRecastLook::Refused, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    back(alert: "No look made: #{e.message}.")
    nil
  end

  # The look stands whatever the build does; anything unexpected is logged against it.
  def build(look)
    rescue_and_log(target: look) { start_build(look) }
  rescue StandardError => e
    back(look: look, alert: "#{look.descriptor} was made, but its character sheet could not start: #{e.message}")
  end

  # The readiness refusals and the busy guard are answers, not ErrorLog rows.
  # The look stands either way; its own page can build the sheet later.
  def start_build(look)
    Appearances::SheetBuild.start!(look, number: params[:number].presence)
    back(look: look, notice: "#{look.descriptor} made for #{look.person.full_name}. Its character sheet is building in the " \
                 "background; it takes about two minutes, and this card updates itself.")
  rescue Appearances::GenerateArtifact::NoGenerator, Appearances::GenerateArtifact::NoIdentityPhoto,
         Appearances::SheetBuild::Busy => e
    back(look: look, alert: "#{look.descriptor} was made for #{look.person.full_name}, but its character sheet did not start: #{e.message}")
  end
end
