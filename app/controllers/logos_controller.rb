# frozen_string_literal: true

# LOGO STUDIO (epic brand-studio): a read-only gallery over Logos::NavbarLogo
# and Logos::StackedLogo. Three logo TYPES per brand: the icon alone, the
# Navbar Logo and the Stacked Logo (Logos::Variant::TYPES; task
# logo-tabs-icon-and-stacked). The index lists each brand in
# config/logo_brands.yml with one of each; a brand page is TABBED by type
# (?type=, the Navbar Logo unless asked) and shows that type's logos: the icon,
# or the three text versions, a Navbar Logo's on the rule ?rule= picks (4
# unless asked) and a Stacked Logo's in the form ?form= picks (the brand's own
# unless asked: two_line, one_line or tagline), with their guide drawings behind one toggle and the brand's
# `note` on where its art came from; /icon, /navbar and /stacked serve one logo
# as SVG, inline or as a download.
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

  # Per brand, one logo of each type: the samples the table shows. A brand whose name cannot be stacked (its style
  # needs `stacked: one_line`) keeps its row: its Stacked cell holds the refusal, and the cell says why.
  def index
    @rows = Logos::NavbarLogo.brands.map do |brand|
      logo = Logos::NavbarLogo.new(brand)
      [logo, { icon: Logos::Variant.new(logo, type: :icon, tone: @context),
               navbar: Logos::Variant.new(logo, rule: 4, text: :second, tone: @context),
               stacked: stacked_sample(brand) }]
    end
  end

  # Every setting is read on every tab, so a tab that does not use one (the icon has no rule and no guides) still
  # carries it to the next.
  def show
    @rule = Logos::Variant.rule(params[:rule])
    @form = Logos::Variant.form(params[:form], (@logo if @type == :stacked))
    @guides = Logos::Variant.flag(params[:guides], "guides")
    @variants = Logos::Variant.all(@logo, type: @type, rule: @rule, form: @form, tone: @context, guides: @guides)
    @kit = Logos::BrandKit.new(@logo.brand)
  end

  # One logo as SVG. The type comes from the route (/icon, /navbar, /stacked), never from the query string.
  def asset
    variant = Logos::Variant.parse(@logo, params, type: @type)
    download = Logos::Variant.flag(params[:download], "download")
    send_data variant.svg, type: "image/svg+xml", filename: variant.filename, disposition: download ? "attachment" : "inline"
  end

  private

  def stacked_sample(brand)
    Logos::Variant.new(Logos::Variant.logo(brand, :stacked), type: :stacked, text: :first, tone: @context)
  rescue Logos::NavbarLogo::Error => e
    e
  end

  def set_context
    @context = Logos::Variant.context(params[:context])
  end

  # An unknown brand is a 404; every other refusal is a 422 (above). The logo is the one that draws the type asked for.
  def set_logo
    brand = params[:brand].to_s
    raise ActiveRecord::RecordNotFound, "No logo brand #{brand.inspect}" unless Logos::NavbarLogo.brands.include?(brand)

    @type = Logos::Variant.type(params[:type])
    @logo = Logos::Variant.logo(brand, @type)
  end
end
