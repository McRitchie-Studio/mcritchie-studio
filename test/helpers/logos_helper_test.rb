# frozen_string_literal: true

require "test_helper"

# [unit] LogosHelper's two measured promises (task logo-tabs-icon-and-stacked):
# the watermark plate is dark enough for the watermark to be read on it, and a
# guide drawing is shown large enough for its labels to be read.
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

  # The lowest contrast of a brand's watermark against any point of a gradient plate.
  def worst_contrast(plate, mark)
    from, to = plate.map { |hex| channels(hex) }
    (0..20).map do |step|
      behind = from.zip(to).map { |a, b| a + (b - a) * step / 20.0 }
      shown = channels(mark.fetch("fill")).zip(behind).map { |fill, back| mark.fetch("opacity") * fill + (1 - mark.fetch("opacity")) * back }
      contrast(shown, behind)
    end.min
  end

  test "every brand's watermark is at least 3:1 against every point of the watermark plate" do
    assert_equal "background-image: linear-gradient(135deg, #263B5C, #2C625E)", logo_plate_style(:watermark)
    Logos::NavbarLogo.brands.each do |brand|
      assert_operator worst_contrast(LogosHelper::WATERMARK_PLATE, Logos::NavbarLogo.new(brand).watermark), :>=, 3.0, brand
    end
    assert_in_delta 2.14, worst_contrast(%w[#3F5E8C #4F9A94], Logos::NavbarLogo::WATERMARK), 0.01, "the plate this replaced measured about 2.1:1"
  end

  # Every guide drawing the gallery can show: 5 brands x (3 rules x 3 texts of the Navbar Logo + 3 texts of each form of
  # the Stacked Logo: two for the four brands with a tagline, one for Turf Monster).
  def guide_drawings
    Logos::NavbarLogo.brands.flat_map do |brand|
      navbar = Logos::Variant::RULES.keys.flat_map { |rule| Logos::Variant.all(Logos::Variant.logo(brand), rule:, guides: true) }
      stacked = Logos::Variant.logo(brand, :stacked)
      navbar + stacked.forms.flat_map { |form| Logos::Variant.all(stacked, type: :stacked, form:, guides: true) }
    end
  end

  def view_box(variant) = Nokogiri::XML(variant.svg).root["viewBox"].split.map(&:to_f)

  test "no guide drawing needs more than the 1028 px plate of a 1280 px page, so nothing scrolls there" do
    assert_equal 72, guide_drawings.size
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
  # plate (the axis column beside the icon, never on it: test/lib/logos_stacked_logo_test.rb). Measured against every
  # point of each plate, both ends of the watermark's gradient included, it reads at 1.4:1 to 2.2:1, and the logo's
  # own text is more than twice as strong. The bar is 2x: at the watermark plate's lighter end (#2C625E) the logo
  # (white at 0.6) is 3.66:1 and its ghost (white at 0.22) 1.69:1, 2.17x; the darker end is 2.68x. Review of PR
  # 2042 found that end under the 2.2x first written here; 2x is the claim the docs make, so the bar went to the
  # claim rather than the watermark ghosts (shared with the Navbar guides) going fainter.
  STRONGER = 2.0

  test "every ghost is visible on every point of its plate and far fainter than the logo's own text" do
    from, to = LogosHelper::WATERMARK_PLATE.map { |hex| channels(hex) }
    gradient = (0..20).map { |step| from.zip(to).map { |a, b| a + (b - a) * step / 20.0 } }   # 21 points, both ends included
    plates = { light: [channels("#FFFFFF")], dark: [channels("#12141A")], watermark: gradient }
    Logos::NavbarLogo.brands.product(Logos::NavbarLogo::TONES).each do |brand, tone|
      logo = Logos::StackedLogo.new(brand)
      fill = tone == :watermark ? logo.watermark.fetch("fill") : Logos::NavbarLogo.styles.fetch(brand).fetch("tones").fetch(tone.to_s).fetch("text")
      text_opacity = tone == :watermark ? logo.watermark.fetch("opacity") : 1
      plates.fetch(tone).each do |plate|
        behind = plate
        seen = ->(opacity) { channels(fill).zip(behind).map { |f, b| opacity * f + (1 - opacity) * b } }
        ghost = contrast(seen.(Logos::StackedLogo::GHOST_OPACITY.fetch(tone)), behind)
        where = "#{brand} #{tone} on #{plate.map(&:round)}"
        assert_operator ghost, :>=, 1.4, "#{where}: visible"
        assert_operator ghost, :<=, 2.2, "#{where}: faint"
        assert_operator contrast(seen.(text_opacity), behind), :>=, STRONGER * ghost, "#{where}: the logo is far the stronger"
      end
    end
    assert_equal [from, to], [gradient.first, gradient.last], "both ends of the gradient"
  end
end
