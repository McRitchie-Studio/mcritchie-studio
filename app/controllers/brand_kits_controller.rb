# frozen_string_literal: true

# THE BRAND KIT RECORD's writes (epic brand-studio, piece 3; task brand-kit-record), all from the logo gallery's
# brand page (/logos/:brand, LogosController#show):
#
#   PATCH  /logos/:brand/kit/choice              save the tab's current Navbar or Stacked choice (?type=)
#   DELETE /logos/:brand/kit/choice              clear it: the brand shows its default again
#   PATCH  /logos/:brand/kit                     the kit's notes
#   POST   /logos/:brand/kit/originals           upload one or more original artwork files
#   GET    /logos/:brand/kit/originals/:id       one original, inline (a picture) or as a download (?download=1)
#   DELETE /logos/:brand/kit/originals/:id       remove one
#
# A choice is read through the gallery's own parser (BrandKit#save_choice), so what is saved is what the page drew.
# A refusal (a choice the page could not draw, a file that is not artwork) is a plain-text 422, like the gallery's.
# A brand's record is created on its first save.
#
# ADMIN ONLY, reads included: the originals are unreleased brand work. They are served from here, behind the wall,
# never from an Active Storage URL, which anyone holding it could open. An SVG is served with a sandboxing CSP, so a
# script inside one never runs on the hub's origin even when it is opened on its own.
class BrandKitsController < ApplicationController
  # The page settings a save or a clear carries back to the brand page, so the operator lands where they were.
  RETURN_PARAMS = (%i[type rule form guides context] + Logos::Variant::EDIT_PARAMS.keys).freeze

  before_action :require_admin
  before_action :set_kit

  rescue_from Logos::NavbarLogo::Error do |error|
    render plain: error.message, status: :unprocessable_content
  end

  rescue_from ActiveRecord::RecordInvalid do |error|
    render plain: error.record.errors.full_messages.to_sentence, status: :unprocessable_content
  end

  def save_choice
    type = choice_type
    variant = @kit.save_choice(type, params, by: who)
    redirect_to back_to_page, notice: "Saved the #{Logos::Variant::TYPES.fetch(type)} kit choice: #{helpers.logo_choice_summary(variant)}."
  end

  def clear_choice
    type = choice_type
    @kit.clear_choice(type, by: who) if @kit.persisted?
    redirect_to back_to_page, notice: "Cleared the #{Logos::Variant::TYPES.fetch(type)} kit choice. The brand shows its default again."
  end

  def update
    @kit.update!(notes: params[:notes].to_s.strip.presence, updated_by: who)
    redirect_to back_to_page(anchor: "kit"), notice: "Saved the kit's notes."
  end

  private

  # An unknown brand is a 404. The record is the brand's own, or a new one its first save creates.
  def set_kit
    brand = params[:brand].to_s
    raise ActiveRecord::RecordNotFound, "No logo brand #{brand.inspect}" unless Logos::NavbarLogo.brands.include?(brand)

    @kit = BrandKit.for(brand)
  end

  def choice_type
    type = params[:type].to_s
    BrandKit::TYPES.find { |known| known.to_s == type } ||
      raise(Logos::NavbarLogo::Error, "unknown type #{type.inspect}: a kit saves a navbar or a stacked choice")
  end

  def who = current_user.email

  # The brand page with the settings the form carried; the Navbar tab is the page's default, so it is not named.
  def back_to_page(anchor: nil)
    page = params.permit(*RETURN_PARAMS).to_h.symbolize_keys.compact_blank
    page.delete(:type) if page[:type] == "navbar"
    logo_brand_path(@kit.brand, page.merge(anchor:).compact)
  end
end
