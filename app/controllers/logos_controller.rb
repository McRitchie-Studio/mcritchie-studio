# frozen_string_literal: true

# LOGO STUDIO (epic brand-studio, task logo-studio-gallery-page): a read-only
# gallery over Logos::NavbarLogo. The index lists each brand in
# config/logo_brands.yml; a brand page shows its twelve Navbar Logos by rule and
# text on a light and a dark plate, with their guide drawings behind one
# toggle; /navbar serves one logo as SVG, inline or as a download.
#
# No model and nothing stored: choosing a logo waits for the brand kit record.
# ADMIN ONLY, like the email brand kits: the drawings are unreleased brand work.
class LogosController < ApplicationController
  # What a brand page says about its own data, in one line.
  NOTES = {
    "industries" => "The Industries icon is drawn flat here, as two solid layers, without the marketing kit's steel gradient and tick marks. That is deliberate in this first version."
  }.freeze

  before_action :require_admin
  before_action :set_logo, except: :index

  # A param the library or the parser refuses: say why in plain text, no page and no trace.
  rescue_from Logos::NavbarLogo::Error do |error|
    render plain: error.message, status: :unprocessable_content
  end

  def index
    @logos = Logos::NavbarLogo.brands.map { |brand| Logos::NavbarLogo.new(brand) }
  end

  def show
    @guides = Logos::Variant.flag(params[:guides], "guides")
    @variants = Logos::Variant.all(@logo, guides: @guides)
    @note = NOTES[@logo.brand]
  end

  def navbar
    variant = Logos::Variant.parse(@logo, params)
    download = Logos::Variant.flag(params[:download], "download")
    send_data variant.svg, type: "image/svg+xml", filename: variant.filename, disposition: download ? "attachment" : "inline"
  end

  private

  # An unknown brand is a 404; every other refusal is a 422 (above).
  def set_logo
    brand = params[:brand].to_s
    raise ActiveRecord::RecordNotFound, "No logo brand #{brand.inspect}" unless Logos::NavbarLogo.brands.include?(brand)

    @logo = Logos::NavbarLogo.new(brand)
  end
end
