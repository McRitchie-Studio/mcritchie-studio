# frozen_string_literal: true

# LOGO STUDIO (epic brand-studio): a gallery over Logos::NavbarLogo
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
# The page's CONTEXT is the hub's own theme (task brand-gallery-palette-and-theme):
# both pages render each logo's light and dark versions and CSS shows the one
# that matches html.dark, so a page opens in whatever theme the hub is in and a
# change of theme needs no request. ?context=watermark turns the page dark and
# shows the watermark logos instead; an explicit ?context=light or dark sets the
# hub's theme to it from the first paint (content_for :html_theme in the views, read by the hub layout and
# app/javascript/theme_context.js; data-logo-theme for a Turbo visit) and otherwise behaves like no context.
#
# The Navbar and Stacked tabs have an EDIT panel (task logo-part-editor): a
# palette colour per part (icon, first word, ending, tagline), a weight per word
# and the tagline's visibility, kept in the URL (Logos::Variant::EDIT_PARAMS),
# carried by every other control, and applied to every logo on the tab and to
# its downloads and copies. A watermark is one colour, so they do not apply there.
#
# The brand's KIT RECORD (BrandKit, task brand-kit-record) holds the saved
# Navbar and Stacked choices and the original artwork: the table draws the
# saved choices, and the brand page shows them and saves them
# (BrandKitsController does the writing).
# ADMIN ONLY, like the email brand kits: the drawings are unreleased brand work.
class LogosController < ApplicationController
  include LogoBrandPage

  before_action :require_admin
  before_action :set_logo, except: :index
  before_action :set_context, only: %i[index show]

  # A param the library or the parser refuses: say why in plain text, no page and no trace.
  rescue_from Logos::NavbarLogo::Error do |error|
    render plain: error.message, status: :unprocessable_content
  end

  # Per brand, one logo of each type: the samples the table shows. A brand whose name cannot be stacked (its style
  # needs `stacked: one_line`) keeps its row: its Stacked cell holds the refusal, and the cell says why.
  # Each sample is a map of the tones it is shown in to its variant (logos/_cluster).
  # The Navbar and Stacked samples are the brand's SAVED kit choices where it has them (BrandKit; task
  # brand-kit-record), else its defaults (BrandKit::DEFAULTS); every saved kit is read in one query.
  def index
    brands = Logos::NavbarLogo.brands
    @kits = BrandKit.by_brand(brands)
    @savers = BrandKit.saver_names(@kits.values)
    @rows = brands.map do |brand|
      logo = Logos::NavbarLogo.new(brand)
      kit = @kits[brand] || BrandKit.new(brand:)
      [logo, { stacked: kit_sample(kit, :stacked), navbar: kit_sample(kit, :navbar),
               icon: @tones.to_h { |tone| [tone, Logos::Variant.new(logo, type: :icon, tone:)] } }]
    end
  end

  # The page is read from its params (LogoBrandPage#load_brand_page), which BrandKitsController shares to draw it again.
  def show
    load_brand_page
  end

  # One logo as SVG. The type comes from the route (/icon, /navbar, /stacked), never from the query string.
  def asset
    variant = Logos::Variant.parse(@logo, params, type: @type)
    download = Logos::Variant.flag(params[:download], "download")
    send_data variant.svg, type: "image/svg+xml", filename: variant.filename, disposition: download ? "attachment" : "inline"
  end

  private

  # A sample is the kit's saved choice or the brand's default, by tone; or the library's refusal, which the cell
  # shows in its place: a brand that cannot be stacked, or a saved choice the brand's data can no longer draw.
  def kit_sample(kit, type)
    @tones.to_h { |tone| [tone, kit.variant(type, tone:)] }
  rescue Logos::NavbarLogo::Error => e
    e
  end
end
