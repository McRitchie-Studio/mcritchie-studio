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
# COMPARE (task logo-compare-and-original-edits): /logos/compare?left=welding&right=welding_v2 draws two brands' kits
# side by side (LogoComparison), each in its kit default unless the page's shared controls change it, with a Show
# grid toggle for both sides' construction guides.
#
# ADMIN ONLY, like the email brand kits: the drawings are unreleased brand work.
class LogosController < ApplicationController
  include LogoBrandPage

  before_action :require_admin
  before_action :set_logo, except: %i[index compare]
  before_action :set_context, only: %i[index show compare]

  # A param the library or the parser refuses: say why in plain text, no page and no trace.
  rescue_from Logos::NavbarLogo::Error do |error|
    render plain: error.message, status: :unprocessable_content
  end

  # Per brand, one logo of each type: the samples the table shows. The icon is in the page's colouring
  # (LogoBrandPage#page_colouring); the Navbar and Stacked samples as #kit_sample says. A brand whose name cannot be stacked (its style
  # needs `stacked: one_line`) keeps its row: its Stacked cell holds the refusal, and the cell says why.
  # Each sample is a map of the tones it is shown in to its variant (logos/_cluster).
  # The Navbar and Stacked samples are the brand's SAVED kit choices where it has them (BrandKit; task
  # brand-kit-record), else its defaults (BrandKit::DEFAULTS); every saved kit is read in one query.
  # THE ICON (task kit-icon-atomic-unit): the kit's saved icon, else the brand's icon in the page's colouring. With a
  # kit icon, all three tiles draw it. Without one, a SAVED Navbar or Stacked choice draws the icon it was saved with
  # (task logos-index-download-formats: the index forced the brand's Original helmet onto Commercial Welding v2's Alt
  # Stacked choice, which its brand page, the /stacked route and the kit export all draw in Alt), so every tile is
  # the logo its brand page shows and its download gives.
  def index
    brands = Logos::NavbarLogo.brands
    @kits = BrandKit.by_brand(brands)
    @app_links = BrandKitApp.by_brand(brands)
    @marketing_kits = BrandMarketingKit.by_brand(brands)
    @rows = brands.map do |brand|
      logo = Logos::NavbarLogo.new(brand)
      kit = @kits[brand] || BrandKit.new(brand:)
      icon = kit.kit_icon || Logos::Variant.new(logo, type: :icon, colouring: page_colouring(logo))
      [logo, { stacked: kit_sample(kit, :stacked), navbar: kit_sample(kit, :navbar),
               icon: @tones.to_h { |tone| [tone, Logos::Variant.new(logo, type: :icon, tone:, colouring: icon.colouring, edits: icon.edits)] } }]
    end
  end

  # The page is read from its params (LogoBrandPage#load_brand_page), which BrandKitsController shares to draw it again.
  def show
    load_brand_page
  end

  # Two brands' kits side by side: ?left= and ?right= (Commercial Welding v1 and v2 unless asked; an unknown brand is a
  # 404, as on a brand page), ?type= (the Navbar Logo unless asked), and the controls both sides share: ?rule=, ?form=
  # ?proportion= and ?colouring= (absent: each side's kit default) and ?grid=1 (the construction guides).
  def compare
    brands = Logos::NavbarLogo.brands
    pair = LogoComparison.default_pair(brands)
    @left, @right = [[:left, pair.first], [:right, pair.last]].map { |key, fallback| compare_brand(params[key], fallback, brands) }
    @type = Logos::Variant.type(params[:type])
    @rule_param = (Logos::Variant.rule(params[:rule]) if params.key?(:rule))
    @form_param = (Logos::Variant.form(params[:form]) if params.key?(:form))
    @proportion_param = (Logos::Variant.proportion(params[:proportion]) if params.key?(:proportion))
    @grid = Logos::Variant.flag(params[:grid], "grid")
    kits = BrandKit.by_brand([@left, @right])
    @savers = BrandKit.saver_names(kits.values)
    @comparison = LogoComparison.new(left: @left, right: @right, type: @type, tones: @tones, rule: @rule_param, form: @form_param,
                                     proportion: @proportion_param, colouring: @colouring_param, grid: @grid, kits:)
  end

  # One logo as SVG. The type comes from the route (/icon, /navbar, /stacked), never from the query string.
  # THE KIT IS THE DEFAULT (task kit-export-and-clear-lens): asked with no choice params (only ?tone= and ?download=),
  # a brand with a saved kit answers with its kit's logo for that tone, exactly as the Kit card and the kit export draw
  # it (BrandKit#variant); any choice param (KIT_OVERRIDES) means the caller says what it wants, and gets exactly that.
  # A brand with nothing saved, or a kit its data can no longer draw, answers exactly as before. X-Logo-Source says
  # which: "kit" or "params".
  def asset
    asked = Logos::Variant.parse(@logo, params, type: @type)
    variant = kit_default(asked.tone) || asked
    download = Logos::Variant.flag(params[:download], "download")
    response.headers["X-Logo-Source"] = variant.equal?(asked) ? "params" : "kit"
    send_data variant.svg, type: "image/svg+xml", filename: variant.filename, disposition: download ? "attachment" : "inline"
  end

  # The params that choose a logo, of any type: one of them in the query and the SVG routes draw what it says, not the kit.
  KIT_OVERRIDES = (Logos::Variant::CHOICES.values.flatten.uniq - %i[tone] + Logos::Variant::EDIT_PARAMS.keys).map(&:to_s).freeze

  # THE KIT AS FILES (task kit-export-and-clear-lens): every saved logo, light, dark and watermark, with a README, as
  # one zip (BrandKitExport). Admin only, like every logo route.
  def kit_export
    send_data kit_files.zip, type: "application/zip", filename: kit_files.zip_filename, disposition: "attachment"
  end

  # One kit file at its stable name (/logos/welding_v2/kit/navbar-dark.svg): always the current kit choice. An unknown
  # name is a 404; a logo the brand cannot draw is a 422 with the reason, as on every logo route.
  def kit_file
    raise ActiveRecord::RecordNotFound, "No kit file #{params[:file].to_s.inspect[0, 60]}" unless BrandKitExport.file?(params[:file])

    download = Logos::Variant.flag(params[:download], "download")
    send_data kit_files.svg(params[:file]), type: "image/svg+xml", filename: "#{@logo.brand}-#{params[:file]}",
                                            disposition: download ? "attachment" : "inline"
  end

  private

  def kit_files
    @kit_files ||= begin
      kit = BrandKit.for(@logo.brand)
      BrandKitExport.new(kit, base_url: request.base_url, saver: BrandKit.saver_names([kit])[kit.updated_by])
    end
  end

  # The brand's kit logo of this type in `tone`, or nil: a choice param was given, nothing is saved, or the kit cannot
  # be drawn (then the route answers as it always has, never a 422 an app did not ask for).
  def kit_default(tone)
    return if KIT_OVERRIDES.any? { |name| params.key?(name) }

    kit = BrandKit.find_by(brand: @logo.brand)
    return unless kit && BrandKit::CHOICE_TYPES.any? { |type| kit.saved?(type) }

    kit.variant(@type, tone:)
  rescue Logos::NavbarLogo::Error
    nil
  end

  def compare_brand(value, fallback, brands)
    return fallback if value.nil?
    raise ActiveRecord::RecordNotFound, "No logo brand #{value.to_s.inspect[0, 40]}" unless brands.include?(value.to_s)

    value.to_s
  end

  # A sample is the kit's saved choice or the brand's default, by tone; or the library's refusal, which the cell
  # shows in its place: a brand that cannot be stacked, or a saved choice the brand's data can no longer draw.
  # A saved choice is shown in its saved colouring, and a default in the brand's own (its Original where it has one),
  # unless the page asks for one (?colouring=), which every brand that has it is shown in.
  # Every sample draws the kit's icon where one is saved (BrandKit#variant), else the icon of its own choice: exactly
  # what LogoBrandPage#load_icon draws on the brand page.
  def kit_sample(kit, type)
    @tones.to_h { |tone| [tone, kit.variant(type, tone:, colouring: @colouring_param)] }
  rescue Logos::NavbarLogo::Error => e
    e
  end
end
