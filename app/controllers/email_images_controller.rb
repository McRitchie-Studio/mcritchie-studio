# frozen_string_literal: true

# EMAIL HEADER BRIEFS (epic email-image-builder, piece 1): open a brief,
# generate a round of candidates, approve or retire them, and see the chosen one
# inside the real email shell.
#
# ADMIN ONLY, READS INCLUDED. Generate buys images on our OpenAI credential and
# hub signup is open, so a signed-in visitor is still the public; `require_admin`
# is the gate (the same argument AppearancesController makes for its sheet
# button). The paid call itself runs in EmailImageBuildJob, claimed once.
class EmailImagesController < ApplicationController
  before_action :require_admin
  before_action :set_brief, except: %i[index create]

  def index
    @briefs = EmailImageBrief.ordered.includes(:candidates).to_a
    @brief = EmailImageBrief.new(text_mode: "baked", image_format: "jpg", preset: "header_2x1")
  end

  def create
    @brief = EmailImageBrief.new(brief_params.merge(created_by: current_user&.email))
    rescue_and_log(target: @brief) do
      if @brief.save
        redirect_to email_image_path(@brief), notice: "Brief opened. Generate a round when it reads right."
      else
        @briefs = EmailImageBrief.ordered.includes(:candidates).to_a
        render :index, status: :unprocessable_content
      end
    end
  end

  def show
    load_show
  end

  def update
    rescue_and_log(target: @brief) do
      if @brief.update(brief_params.except(:app, :email_key, :variant))
        redirect_to email_image_path(@brief), notice: "Brief saved. The next round uses it."
      else
        load_show
        render :show, status: :unprocessable_content
      end
    end
  end

  # THE REFUSALS ARE STATES, not failures (no generator, rounds spent, a round
  # already running): they answer as an alert and write no ErrorLog row.
  def generate
    EmailImages::Build.start!(@brief, count: params[:count].presence&.to_i)
    redirect_to email_image_path(@brief), notice: EmailImages::Build::STARTED_NOTICE
  rescue *EmailImages::Build::REFUSALS => e
    redirect_to email_image_path(@brief), alert: e.message
  end

  def approve
    artifact = candidate!
    rescue_and_log(target: @brief) { @brief.approve!(artifact, by: current_user&.email) }
    redirect_to email_image_path(@brief, candidate: artifact.slug), notice: "Approved. It is the header for #{@brief.catalog_key}."
  end

  def retire
    artifact = candidate!
    rescue_and_log(target: @brief) { @brief.retire!(artifact) }
    redirect_to email_image_path(@brief), notice: "Retired."
  end

  # THE REAL EMAIL SHELL around one candidate: the engine's branded_mailer
  # layout, which every app's mailer renders. `baked` shows the flat <img> the
  # layout draws from @banner_url; `none` builds a Studio::Banner so the
  # engine's layered banner sets the headline as live text over the art.
  # Rendered alone so the page can frame it at true email width.
  def preview
    @preview_artifact = preview_artifact
    if @preview_artifact
      if @brief.text_mode == "none"
        @banner = Studio::Banner.new(background_url: @preview_artifact.image_url, header: @brief.headline,
                                     subtext: @brief.subtext.presence)
      else
        @banner_url = @preview_artifact.image_url
        @banner_alt = @brief.effective_alt_text
      end
    end
    render layout: "email_images/preview_shell"
  end

  private

  def set_brief
    @brief = EmailImageBrief.find_by!(slug: params[:slug])
  end

  def candidate!
    @brief.candidates.find_by!(slug: params[:artifact_slug])
  end

  def load_show
    @candidates = @brief.candidates.to_a
    generator = EmailImages::Generate.new(@brief)
    @generator_row = generator.row
    @preferred_row = ImageGeneration::Registry.preferred(EmailImages::Generate::CAPABILITY)
    @preview_artifact = preview_artifact
  end

  # Which candidate the preview shows: the one asked for, else the approved
  # one, else the newest live one.
  def preview_artifact
    candidates = @candidates || @brief.candidates.to_a
    (params[:candidate].presence && candidates.find { |a| a.slug == params[:candidate] }) ||
      @brief.approved_artifact ||
      candidates.find { |a| a.retired_at.nil? }
  end

  def brief_params
    params.require(:email_image_brief).permit(:app, :email_key, :variant, :brand_kit, :preset, :text_mode,
                                              :image_format, :headline, :subtext, :alt_text, :prompt_notes, :max_rounds)
  end
end
