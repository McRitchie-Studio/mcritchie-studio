# frozen_string_literal: true

# "Generate a new look" on a cast card: makes a look for the athlete the
# operator chose and starts its character sheet through the one existing build
# (Appearances::SheetBuild, in a job). Admin only: THE SHEET SPENDS MONEY, and
# hub signup is open, so a session alone is no cost control. Nothing here calls
# a generator; the request claims the look, enqueues, and returns.
class VideoPerformerRecastLooksController < ApplicationController
  before_action :require_admin
  before_action :set_performer

  # WHICH SHEETS TO BUILD, chosen on the form, each one a paid GPT-5 image:
  # the look's own sheet (the default, as before), its iced twin's, both (two
  # builds, and the form says so), or none. Never two unless "both" was picked.
  SHEETS = %w[standard iced both none].freeze

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
    p = params.permit(:person_slug, :descriptor, :reference_url, :number)
    { person_slug: p[:person_slug], descriptor: p[:descriptor], reference_url: p[:reference_url], jersey_number: p[:number] }
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

  def sheets_choice = SHEETS.include?(params[:sheets]) ? params[:sheets] : "standard"

  # The looks whose sheets were asked for, in build order.
  def build_targets(look)
    twin = look.iced_twin
    case sheets_choice
    when "standard" then [look]
    when "iced" then [twin]
    when "both" then [look, twin]
    else []
    end.compact
  end

  # The look stands whatever the build does; anything unexpected is logged against it.
  def build(look)
    targets = build_targets(look)
    made = "#{look.descriptor} made for #{look.person.full_name}, with its iced twin"
    return back(look: look, notice: "#{made}. No sheet was built; build one from the look's page.") if targets.empty?

    started, refused = start_builds(targets)
    flash_key = refused.any? ? :alert : :notice
    back(look: look, flash_key => [made + ".", started_sentence(started), *refused].compact.join(" "))
  end

  # Each build is its own claim and its own paid job. The readiness refusals and
  # the busy guard are answers, not ErrorLog rows; anything else is logged
  # against that look and reported, and the other build still starts.
  def start_builds(targets)
    started = []
    refused = []
    targets.each do |target|
      rescue_and_log(target: target) { start_one(target, started, refused) }
    rescue StandardError => e
      refused << "#{sheet_name(target)} could not start: #{e.message}"
    end
    [started, refused]
  end

  def start_one(target, started, refused)
    Appearances::SheetBuild.start!(target, number: params[:number].presence)
    started << target
  rescue Appearances::GenerateArtifact::NoGenerator, Appearances::GenerateArtifact::NoIdentityPhoto,
         Appearances::SheetBuild::Busy => e
    refused << "#{sheet_name(target)} did not start: #{e.message}"
  end

  def sheet_name(look) = look.iced? ? "The iced character sheet" : "Its character sheet"

  def started_sentence(started)
    return nil if started.empty?

    what = started.map { |t| t.iced? ? "the iced sheet" : "the character sheet" }.to_sentence
    builds = started.length == 1 ? "one paid build" : "#{started.length} paid builds"
    "Building #{what} in the background (#{builds}); it takes about two minutes, and this card updates itself."
  end
end
