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
# A refused choice is a plain-text 422, like the gallery's. A refused upload (a file that is not artwork) draws the
# brand page again, as a 422, with the reason in the Kit originals card (LogoBrandPage; task logo-gallery-polish-pass).
# A brand's record is created on its first save.
#
# ADMIN ONLY, reads included: the originals are unreleased brand work. They are served from here, behind the wall,
# never from an Active Storage URL, which anyone holding it could open. An SVG is served with a sandboxing CSP, so a
# script inside one never runs on the hub's origin even when it is opened on its own.
class BrandKitsController < ApplicationController
  include LogoBrandPage

  # The page settings a save or a clear carries back to the brand page, so the operator lands where they were.
  RETURN_PARAMS = (%i[type rule form guides context colouring] + Logos::Variant::EDIT_PARAMS.keys).freeze
  # An original is served with no power of its own: an SVG opened by itself draws, but runs no script and loads nothing.
  ORIGINAL_CSP = "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox"

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
    variant = logged { @kit.save_choice(type, params, by: who) }
    # The saved choice is the tab's default now (task logo-original-and-alt, item 9): back to the bare tab, which opens
    # on it, at its Kit choice card, or at the top from the tab's own Save as default (return=top).
    anchor = ("kit-choice" unless params[:return] == "top")
    redirect_to back_to_page(anchor:, keep: %i[type guides context]), notice: "Saved the #{Logos::Variant::TYPES.fetch(type)} kit choice: #{helpers.logo_choice_summary(variant)}."
  end

  def clear_choice
    type = choice_type
    logged { @kit.clear_choice(type, by: who) } if @kit.persisted?
    redirect_to back_to_page(anchor: "kit-choice"), notice: "Cleared the #{Logos::Variant::TYPES.fetch(type)} kit choice. The brand shows its default again."
  end

  def update
    logged { @kit.update!(notes: params[:notes].to_s.strip.presence, updated_by: who) }
    redirect_to back_to_page(anchor: "kit"), notice: "Saved the kit's notes."
  end

  def create_original
    files = Array(params[:originals]).compact_blank
    logged { @kit.add_originals(files, by: who) }
    names = @kit.originals.last(files.size).map { |original| original.filename.to_s }
    redirect_to back_to_page(anchor: "kit-originals"),
                notice: "Uploaded #{helpers.pluralize(names.size, 'original')}: #{names.to_sentence}."
  rescue Logos::NavbarLogo::Error, ActiveRecord::RecordInvalid => e
    refuse_upload(e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message)
  end

  def original
    attachment = @kit.originals.find(params[:id])
    download = Logos::Variant.flag(params[:download], "download")
    inline = !download && BrandKit::PREVIEWABLE.include?(attachment.content_type)
    response.headers["Content-Security-Policy"] = ORIGINAL_CSP
    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data attachment.download, type: attachment.content_type, filename: attachment.filename.to_s,
                                   disposition: inline ? "inline" : "attachment"
  end

  def destroy_original
    removed = logged { @kit.remove_original(params[:id], by: who) }
    redirect_to back_to_page(anchor: "kit-originals"), notice: "Removed #{removed.filename}."
  end

  private

  # A kit write, with its failure logged against the kit (Studio::ErrorHandling#rescue_and_log, which re-raises: a
  # refusal still reaches the rescue_from above, or create_original's own rescue). Only a saved kit is named as the
  # target: logging names it by reference, and a kit not yet saved would be saved by the log itself.
  def logged(&)
    rescue_and_log(target: (@kit if @kit.persisted?), &)
  end

  # The brand page again, on the tab and in the context the upload form carried, with `reason` in the Kit originals
  # card and every other card as it was. The kit is read afresh, so nothing of the refused upload is shown.
  def refuse_upload(reason)
    set_logo
    set_context
    load_brand_page
    @original_refusal = reason
    render "logos/show", status: :unprocessable_content
  end

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
  def back_to_page(anchor: nil, keep: RETURN_PARAMS)
    page = params.permit(*keep).to_h.symbolize_keys.compact_blank
    page.delete(:type) if page[:type] == "navbar"
    logo_brand_path(@kit.brand, page.merge(anchor:).compact)
  end
end
