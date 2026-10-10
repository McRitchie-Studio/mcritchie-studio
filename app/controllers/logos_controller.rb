# frozen_string_literal: true

# LOGO STUDIO (epic brand-studio): a read-only gallery over Logos::NavbarLogo
# and Logos::StackedLogo. Three logo TYPES per brand: the icon alone, the
# Navbar Logo and the Stacked Logo (Logos::Variant::TYPES; task
# logo-tabs-icon-and-stacked). The index lists each brand in
# config/logo_brands.yml with one of each; a brand page shows one type's logos,
# with their guide drawings behind one toggle and the brand's `note` on where
# its art came from; /icon, /navbar and /stacked serve one logo as SVG, inline
# or as a download.
#
# Both pages show each logo ONCE, in the context ?context= names (light, dark
# or watermark), so one dropdown switches every logo together.
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

  # Per brand, one logo of each type: the samples the table shows.
  def index
    @rows = Logos::NavbarLogo.brands.map do |brand|
      logo = Logos::NavbarLogo.new(brand)
      [logo, { icon: Logos::Variant.new(logo, type: :icon, tone: @context),
               navbar: Logos::Variant.new(logo, rule: 4, text: :second, tone: @context),
               stacked: Logos::Variant.new(Logos::Variant.logo(brand, :stacked), type: :stacked, text: :first, tone: @context) }]
    end
  end

  def show
    @guides = Logos::Variant.flag(params[:guides], "guides")
    @variants = Logos::Variant::RULES.keys.flat_map { |rule| Logos::Variant.all(@logo, rule:, tone: @context, guides: @guides) }
  end

  # One logo as SVG. The type comes from the route (/icon, /navbar, /stacked), never from the query string.
  def asset
    type = Logos::Variant.type(params[:type])
    variant = Logos::Variant.parse(Logos::Variant.logo(@logo.brand, type), params, type:)
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
