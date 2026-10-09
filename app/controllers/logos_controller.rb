# frozen_string_literal: true

# LOGO STUDIO (epic brand-studio, task logo-studio-gallery-page): a read-only
# gallery over Logos::NavbarLogo. The index lists each brand in
# config/logo_brands.yml; a brand page shows its Navbar Logos by rule and text,
# with their guide drawings behind one toggle and the brand's `note` on where
# its art came from; /navbar serves one logo as SVG, inline or as a download.
#
# Both pages show each logo ONCE, in the context ?context= names (light, dark
# or watermark; task logo-gallery-context-dropdown), so one dropdown switches
# every logo together.
#
# No model and nothing stored: choosing a logo waits for the brand kit record.
# ADMIN ONLY, like the email brand kits: the drawings are unreleased brand work.
class LogosController < ApplicationController
  before_action :require_admin
  before_action :set_logo, except: :index
  before_action :set_context, only: %i[index show]

  # A param the library or the parser refuses: say why in plain text, no page and no trace.
  rescue_from Logos::NavbarLogo::Error do |error|
    render plain: error.message, status: :unprocessable_content
  end

  def index
    @logos = Logos::NavbarLogo.brands.map { |brand| Logos::NavbarLogo.new(brand) }
  end

  def show
    @guides = Logos::Variant.flag(params[:guides], "guides")
    @variants = Logos::Variant.all(@logo, tone: @context, guides: @guides)
  end

  def navbar
    variant = Logos::Variant.parse(@logo, params)
    download = Logos::Variant.flag(params[:download], "download")
    send_data variant.svg, type: "image/svg+xml", filename: variant.filename, disposition: download ? "attachment" : "inline"
  end

  private

  def set_context
    @context = Logos::Variant.context(params[:context])
  end

  # An unknown brand is a 404; every other refusal is a 422 (above).
  def set_logo
    brand = params[:brand].to_s
    raise ActiveRecord::RecordNotFound, "No logo brand #{brand.inspect}" unless Logos::NavbarLogo.brands.include?(brand)

    @logo = Logos::NavbarLogo.new(brand)
  end
end
