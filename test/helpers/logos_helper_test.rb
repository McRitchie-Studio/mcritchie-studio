# frozen_string_literal: true

require "test_helper"

# [unit] LogosHelper's measured promises (task logo-tabs-icon-and-stacked): the
# watermark is readable where it is shown, and a guide drawing is shown large
# enough for its labels to be read. Task brand-gallery-palette-and-theme: no
# plates (the hub's own card is the background), a logo's light and dark
# versions switched by html.dark, the cluster's sizes and badges, and the
# typeface hierarchy's steps.
class LogosHelperTest < ActionView::TestCase
  def channels(hex) = hex.delete("#").scan(/../).map { |pair| pair.hex.to_f }

  # WCAG relative luminance and contrast ratio.
  def luminance(rgb)
    red, green, blue = rgb.map { |value| (v = value / 255.0) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4 }
    0.2126 * red + 0.7152 * green + 0.0722 * blue
  end

  def contrast(one, other)
    dark, light = [luminance(one), luminance(other)].minmax
    (light + 0.05) / (dark + 0.05)
  end

  # No plates (task brand-gallery-palette-and-theme): a logo sits on the hub's own card, whose background is the hub
  # theme's --color-surface, measured in a browser on 2026-10-10 (studio-engine 0.102.0): white in the light theme,
  # #3C3853 in the dark one. The watermark context turns the page dark, so a watermark sits on the dark card.
  HUB_SURFACES = { light: "#FFFFFF", dark: "#3C3853", watermark: "#3C3853" }.freeze

  def seen_on(fill, opacity, behind) = channels(fill).zip(channels(behind)).map { |f, b| opacity * f + (1 - opacity) * b }

  test "no plate style is left in the helper: the page's own background is the only one" do
    refute respond_to?(:logo_plate_style)
    refute LogosHelper.const_defined?(:LOGO_PLATES)
    refute LogosHelper.const_defined?(:WATERMARK_PLATE)
  end

  test "every brand's watermark is at least 3:1 on the dark card the watermark context puts it on" do
    Logos::NavbarLogo.brands.each do |brand|
      mark = Logos::NavbarLogo.new(brand).watermark
      shown = seen_on(mark.fetch("fill"), mark.fetch("opacity"), HUB_SURFACES.fetch(:watermark))
      assert_operator contrast(shown, channels(HUB_SURFACES.fetch(:watermark))), :>=, 3.0, brand
    end
  end

  # Every guide drawing the gallery can show: 4 brands x (2 rules x 3 texts of the Navbar Logo + 3 texts of each form of
  # the Stacked Logo: two for the three brands with a tagline, one for Turf Monster).
  def guide_drawings
    Logos::NavbarLogo.brands.flat_map do |brand|
      navbar = Logos::Variant::RULES.keys.flat_map { |rule| Logos::Variant.all(Logos::Variant.logo(brand), rule:, guides: true) }
      stacked = Logos::Variant.logo(brand, :stacked)
      navbar + stacked.forms.flat_map { |form| Logos::Variant.all(stacked, type: :stacked, form:, guides: true) }
    end
  end

  def view_box(variant) = Nokogiri::XML(variant.svg).root["viewBox"].split.map(&:to_f)

  test "no guide drawing needs more than the 1028 px plate of a 1280 px page, so nothing scrolls there" do
    assert_equal 57, guide_drawings.size
    guide_drawings.each { |variant| assert_operator logo_guide_min_width(variant), :<=, LogosHelper::LOGO_PLATE_WIDTH, variant.label }
    widest = guide_drawings.max_by { |variant| logo_guide_min_width(variant) }
    # Task navbar-spacing-and-rotated-guides: the ruler's copies are now tracked as the real line is, so the widest
    # drawing became Industries' tagline form (1127 px at 28-unit labels; 986 px at the 32-unit labels it now has), and
    # 993 px once the word gap became half a cap height.
    assert_equal ["McRitchie Industries stacked logo, with tagline, homogeneous, light, construction guides", 993], [widest.label, logo_guide_min_width(widest)]
  end

  test "at its least width every guide drawing's labels are at least 9 px, read from the drawing itself" do
    guide_drawings.each do |variant|
      svg = Nokogiri::XML(variant.svg).remove_namespaces!
      sizes = svg.css("text").map { |label| label["font-size"].to_f }
      assert_operator sizes.size, :>=, 2, variant.label
      assert_equal [variant.guide_font.to_f], sizes.uniq, variant.label
      assert_in_delta view_box(variant)[2], variant.guide_width, 0.001, variant.label
      scale = logo_guide_min_width(variant) / view_box(variant)[2]
      assert_operator sizes.min * scale, :>=, 9.0, variant.label
      assert_operator sizes.min * (logo_guide_min_width(variant) - 1) / view_box(variant)[2], :<, 9.0, "#{variant.label}: and no wider than it needs to be"
    end
  end

  test "a guide drawing's least width never asks for more height than its cap, so the picture is never stretched" do
    guide_drawings.each do |variant|
      _, _, width, height = view_box(variant)
      assert_operator logo_guide_min_width(variant) * height / width, :<=, logo_height(variant), variant.label
    end
  end

  test "a logo scales down inside its plate, and a guide drawing stops at its least width" do
    logo = Logos::NavbarLogo.new("studio")
    plain = Nokogiri::HTML.fragment(logo_image(Logos::Variant.new(logo, rule: 4), height: 60)).at_css("img")
    assert_equal ["max-height: 60px", "block max-w-full w-auto h-auto"], [plain["style"], plain["class"]]
    guide = Logos::Variant.new(logo, rule: 4, guides: true)
    held = Nokogiri::HTML.fragment(logo_image(guide, height: logo_height(guide))).at_css("img")
    assert_equal ["max-height: 132px; min-width: #{logo_guide_min_width(guide)}px", "block max-w-full w-auto h-auto mx-auto", guide.label],
                 [held["style"], held["class"], held["alt"]]
    assert_equal({ icon: 160, navbar: 60, stacked: 240 }, %i[icon navbar stacked].to_h { |type| [type, logo_height(Logos::Variant.new(Logos::Variant.logo("studio", type), type:))] })
  end

  # Task stacked-tagline-and-ghost-grid: a ghost is the logo's own text colour, faint, and every ghost stands on the
  # background (once a plate; since task brand-gallery-palette-and-theme the hub's card) (the axis column beside the icon, never on it: test/lib/logos_stacked_logo_test.rb). Measured against every
  # point of each plate, both ends of the watermark's gradient included, it reads at 1.4:1 to 2.2:1, and the logo's
  # own text is more than twice as strong. The bar is 2x: at the watermark plate's lighter end (#2C625E) the logo
  # (white at 0.6) is 3.66:1 and its ghost (white at 0.22) 1.69:1, 2.17x; the darker end is 2.68x. Review of PR
  # 2042 found that end under the 2.2x first written here; 2x is the claim the docs make, so the bar went to the
  # claim rather than the watermark ghosts (shared with the Navbar guides) going fainter.
  STRONGER = 2.0

  test "every ghost is visible on the hub card it sits on and far fainter than the logo's own text" do
    Logos::NavbarLogo.brands.product(Logos::NavbarLogo::TONES).each do |brand, tone|
      logo = Logos::StackedLogo.new(brand)
      fill = tone == :watermark ? logo.watermark.fetch("fill") : Logos::NavbarLogo.styles.fetch(brand).fetch("tones").fetch(tone.to_s).fetch("text")
      text_opacity = tone == :watermark ? logo.watermark.fetch("opacity") : 1
      behind = HUB_SURFACES.fetch(tone)
      ghost = contrast(seen_on(fill, Logos::StackedLogo::GHOST_OPACITY.fetch(tone), behind), channels(behind))
      where = "#{brand} #{tone} on #{behind}"
      assert_operator ghost, :>=, 1.4, "#{where}: visible"
      assert_operator ghost, :<=, 2.2, "#{where}: faint"
      assert_operator contrast(seen_on(fill, text_opacity, behind), channels(behind)), :>=, STRONGER * ghost, "#{where}: the logo is far the stronger"
    end
  end

  test "a light and dark pair is switched by html.dark alone, and a single tone is shown as it is" do
    logo = Logos::NavbarLogo.new("studio")
    pair = Logos::NavbarLogo::BAKED.to_h { |tone| [tone, Logos::Variant.new(logo, rule: 4, tone:)] }
    html = Nokogiri::HTML.fragment(logo_themed_images(pair, height: 28))
    assert_equal [%w[light contents\ dark:hidden], %w[dark hidden\ dark:contents]],
                 html.css("[data-test='logo-themed']").map { |span| [span["data-tone"], span["class"]] }
    assert_equal %w[light dark], html.css("img").map { |img| img["src"][/tone=(\w+)/, 1] }
    assert_equal %w[eager eager], html.css("img").map { |img| img["loading"] }, "a hidden picture is loaded before the theme turns"

    single = Nokogiri::HTML.fragment(logo_themed_images({ watermark: Logos::Variant.new(logo, tone: :watermark) }, height: 28))
    assert_empty single.css("[data-test='logo-themed']")
    assert_equal ["watermark"], single.css("img").map { |img| img["src"][/tone=(\w+)/, 1] }
  end

  test "only the watermark is carried in a page link; light and dark are the hub theme's" do
    @type, @rule, @guides = :navbar, 4, false
    { nil => {}, light: {}, dark: {}, watermark: { context: :watermark } }.each do |context, carried|
      @context = context
      assert_equal carried, logo_page_params, context.inspect
    end
  end

  test "the cluster's samples fit their tiles under the badges, and every type has a badge" do
    assert_equal({ icon: 28, navbar: 28, stacked: 88 }, LogosHelper::LOGO_SAMPLE_HEIGHTS)
    assert_equal Logos::Variant::TYPES.keys.sort, LogosHelper::LOGO_BADGES.keys.sort
    assert_equal %w[Stacked Navbar Icon], LogosHelper::LOGO_BADGES.values
  end

  test "each typeface level is smaller than the one above, at both sizes, for up to three levels" do
    [false, true].each do |compact|
      sizes = (0...Logos::BrandKit::MAX_LEVELS).map { |level| logo_typeface_size(level, compact:) }
      assert_equal sizes.sort.reverse.uniq, sizes, "compact: #{compact}"
    end
  end
end
