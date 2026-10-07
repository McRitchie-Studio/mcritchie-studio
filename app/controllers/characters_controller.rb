# frozen_string_literal: true

# THE CAST: our fictional characters (mascots and puppets), each with its looks
# and every image it appears in. Epic email-image-builder, addendum
# "Characters", piece A.
#
# ADMIN ONLY, READS INCLUDED, like the person page and the brand kits: hub
# signup is open, the page shows unapproved art, and three actions write (one
# to our bucket). #build_sheet SPENDS: it starts one paid character-sheet build
# through Appearances::SheetBuild, the same claim the person page uses.
class CharactersController < ApplicationController
  before_action :require_admin
  before_action :set_character, except: %i[index new create]
  before_action :set_look, only: %i[upload_art make_default build_sheet]

  def index
    @characters = Character.live.ordered.to_a
    slugs = @characters.map(&:slug)
    @look_counts = Appearance.live.where(character_slug: slugs).group(:character_slug).count
    @avatars = avatar_urls(@characters)
  end

  def show
    load_show
    @look = @character.appearances.new
  end

  def new
    @character = Character.new(kind: "mascot")
  end

  def create
    @character = Character.new(character_params)
    rescue_and_log do
      if @character.save
        redirect_to character_path(@character), notice: "#{@character.name} joined the cast. Add a first look."
      else
        render :new, status: :unprocessable_content
      end
    end
  end

  def edit; end

  def update
    attrs = character_params
    retired = params.dig(:character, :retired)
    attrs[:retired_at] = (retired == "1" ? (@character.retired_at || Time.current) : nil) unless retired.nil?
    rescue_and_log(target: @character) do
      if @character.update(attrs)
        redirect_to character_path(@character), notice: "Saved #{@character.name}."
      else
        render :edit, status: :unprocessable_content
      end
    end
  end

  # A NEW LOOK OWNED BY THIS CHARACTER, with its first piece of art when one is
  # attached. The look is saved first; art that fails to store is reported and
  # leaves the look in place to try again.
  def create_look
    @look = @character.appearances.new(look_params.except(:art, :art_label))
    rescue_and_log(target: @character) do
      unless @look.save
        load_show
        return render :show, status: :unprocessable_content
      end

      notice = "Added the #{@look.descriptor} look."
      art = attach_art(@look, look_params[:art], look_params[:art_label])
      if art && !art.persisted?
        return redirect_to character_path(@character),
                           alert: "#{notice} Its art was not added: #{art.errors.full_messages.to_sentence}."
      end
      redirect_to character_path(@character), notice: notice
    end
  end

  def upload_art
    art = rescue_and_log(target: @look) do
      Characters::UploadLookArt.call(appearance: @look, file: params[:art], label: params[:art_label])
    end
    if art.persisted?
      redirect_to character_path(@character), notice: "Added art to #{@look.descriptor}. The next sheet build sends it."
    else
      redirect_to character_path(@character), alert: "Art not added: #{art.errors.full_messages.to_sentence}."
    end
  end

  def make_default
    rescue_and_log(target: @look) { @look.make_default! }
    redirect_to character_path(@character), notice: "#{@look.descriptor} is now #{@character.name}'s default look."
  end

  # ⚠ SPENDS MONEY: one character sheet, built off the request (SheetBuildJob).
  # The free refusals (no generator, no art, a build already running) are states,
  # not failures, and get no ErrorLog row.
  def build_sheet
    rescue_and_log(target: @look) do
      Appearances::SheetBuild.start!(@look)
      redirect_to character_path(@character), notice: Appearances::SheetBuild::STARTED_NOTICE
    rescue Appearances::GenerateArtifact::NoGenerator,
           Appearances::GenerateArtifact::NoIdentityPhoto,
           Appearances::SheetBuild::Busy => e
      redirect_to character_path(@character), alert: e.message
    end
  rescue StandardError => e
    redirect_to character_path(@character), alert: "Could not start the sheet build: #{e.message}"
  end

  private

  def set_character
    @character = Character.find_by!(slug: params[:slug])
  end

  def set_look
    @look = @character.appearances.live.find_by!(slug: params[:look_slug])
  end

  def character_params
    params.require(:character).permit(:name, :slug, :kind, :brand, :bio, :personality, :voice_notes, :avatar_url)
  end

  def look_params
    params.fetch(:appearance, {}).permit(:descriptor, :colorway, :generation_notes, :reference_url, :art, :art_label)
  end

  def attach_art(look, file, label)
    return nil if file.blank?

    Characters::UploadLookArt.call(appearance: look, file: file, label: label)
  end

  # EVERYTHING THE PROFILE SHOWS, in a fixed number of queries whatever the
  # number of looks: the looks, their chosen art, their newest sheet, and every
  # live image the character is a subject of.
  def load_show
    @looks = @character.appearances.live.order(:created_at, :id).to_a
    slugs = @looks.map(&:slug)
    @art_by_look = AppearanceReferencePhoto.where(appearance_slug: slugs).chosen.gallery_order
                                           .group_by(&:appearance_slug)
    @sheets = Artifact.newest_character_sheets(slugs)
    @artifacts = Artifact.live.joins(:subjects)
                         .where(artifact_subjects: { character_slug: @character.slug })
                         .includes(subjects: %i[person character appearance])
                         .order(created_at: :desc).distinct.to_a
    @kit = @character.brand_kit
  end

  # A cast card's picture: the character's own avatar, else its default look's
  # newest sheet, else that look's first chosen art. Two queries for the list.
  def avatar_urls(characters)
    defaults = characters.filter_map(&:default_appearance_slug)
    sheets = Artifact.newest_character_sheets(defaults)
    art = AppearanceReferencePhoto.where(appearance_slug: defaults).chosen.gallery_order
                                  .group_by(&:appearance_slug)
    characters.to_h do |c|
      look = c.default_appearance_slug
      [c.slug, c.avatar_url.presence || sheets[look]&.image_url || art[look]&.first&.display_url]
    end
  end
end
