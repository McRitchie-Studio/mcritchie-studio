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

  # Every guide drawing the gallery can show: 4 brands x (2 rules x 3 texts of the Navbar Logo + 3 texts of the Stacked Logo).
  def guide_drawings
    Logos::NavbarLogo.brands.flat_map do |brand|
      navbar = Logos::Variant::RULES.keys.flat_map { |rule| Logos::Variant.all(Logos::Variant.logo(brand), rule:, guides: true) }
      navbar + Logos::Variant.all(Logos::Variant.logo(brand, :stacked), type: :stacked, guides: true)
    end
  end

  def view_box(variant) = Nokogiri::XML(variant.svg).root["viewBox"].split.map(&:to_f)

  test "no guide drawing needs more than the 1028 px plate of a 1280 px page, so nothing scrolls there" do
    assert_equal 36, guide_drawings.size
    guide_drawings.each { |variant| assert_operator logo_guide_min_width(variant), :<=, LogosHelper::LOGO_PLATE_WIDTH, variant.label }
    widest = guide_drawings.max_by { |variant| logo_guide_min_width(variant) }
    assert_equal ["McRitchie Industries navbar logo, rule of 4, homogeneous, light, construction guides", 874], [widest.label, logo_guide_min_width(widest)]
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
end
