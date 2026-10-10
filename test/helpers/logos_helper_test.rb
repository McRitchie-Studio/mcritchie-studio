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

  test "every guide drawing's labels are at least 11 px tall at the height the page shows it" do
    Logos::NavbarLogo.brands.product(%i[navbar stacked], Logos::Variant::RULES.keys, Logos::Variant::TEXTS.keys) do |brand, type, rule, text|
      variant = Logos::Variant.new(Logos::Variant.logo(brand, type), type:, rule:, text:, guides: true)
      svg = Nokogiri::XML(variant.svg).remove_namespaces!
      drawn = svg.root["viewBox"].split.last.to_f
      sizes = svg.css("text").map { |label| label["font-size"].to_f }
      assert_operator sizes.size, :>=, 2, variant.label
      assert_operator sizes.min * logo_height(variant) / drawn, :>=, 11.0, variant.label
    end
  end

  test "a logo scales down inside its plate, and a guide drawing keeps its height" do
    logo = Logos::NavbarLogo.new("studio")
    plain = Nokogiri::HTML.fragment(logo_image(Logos::Variant.new(logo, rule: 4), height: 60)).at_css("img")
    assert_equal ["max-height: 60px", "block max-w-full w-auto h-auto"], [plain["style"], plain["class"]]
    guide = Logos::Variant.new(logo, rule: 4, guides: true)
    fixed = Nokogiri::HTML.fragment(logo_image(guide, height: logo_height(guide), fixed: true)).at_css("img")
    assert_equal ["height: 132px; max-width: none", "block mx-auto w-auto", guide.label], [fixed["style"], fixed["class"], fixed["alt"]]
    assert_equal({ icon: 160, navbar: 60, stacked: 240 }, %i[icon navbar stacked].to_h { |type| [type, logo_height(Logos::Variant.new(Logos::Variant.logo("studio", type), type:))] })
  end
end
