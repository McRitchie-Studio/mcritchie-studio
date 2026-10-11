# frozen_string_literal: true

# [unit] The brands' ORIGINAL colourings (task logo-original-and-alt): each brand's true art, traced or taken from its
# kit, as the shipped data and styles draw it.

require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"

class LogosOriginalsTest < Minitest::Test
  Navbar = Logos::NavbarLogo
  Stacked = Logos::StackedLogo

  def fills(svg) = svg.scan(/fill="([^"]+)"/).flatten.uniq

  # Commercial Welding's original is its square logo (COM - Square - Large.png), traced: a blue silhouette, the white
  # right half and lens window over it, the spark over that. The white is OPAQUE, so the helmet holds on a dark page.
  def test_commercial_weldings_original_keeps_its_white_filled_helmet
    icon = Navbar.icons.fetch("welding_original")
    assert_equal %w[blue white accent], icon.fetch("layers").map { |layer| layer["role"] }, "painter's order: silhouette, white, spark"
    assert_equal [858, 975], [icon["w"], icon["h"]], "cropped to the helmet"
    logo = Navbar.new("welding")
    %i[light dark].each do |tone|
      svg = logo.icon_svg(tone:, colouring: :original)
      assert_equal %w[#2E5E8E #FFFFFF #D5752B], fills(svg), "#{tone}: the fills sampled from the PNG, the white included"
      refute_match(/opacity/, svg, "#{tone}: nothing translucent")
      assert_equal 3, svg.scan("<path").size, "#{tone}: the three-colour helmet, never the single-colour one"
    end
  end

  def test_commercial_weldings_original_letters_in_the_kits_blue_and_orange_and_white_on_dark
    logo = Navbar.new("welding")
    assert_equal %w[#2E5E8E #FFFFFF #D5752B #2D5E8E], fills(logo.svg(rule: 3, tone: :light, colouring: :original))
    assert_equal %w[#2E5E8E #FFFFFF #D5752B #D7602E #2D5E8E], fills(logo.svg(rule: 3, text: :first, tone: :light, colouring: :original))
    assert_equal %w[#2E5E8E #FFFFFF #D5752B #D7602E], fills(logo.svg(rule: 3, text: :second, tone: :dark, colouring: :original)),
                 "on dark the name is white, the leading word orange"
    tagline = Stacked.new("welding").svg(form: :tagline, tone: :light, colouring: :original)
    assert_includes fills(tagline), "#D7602E", "the tagline is the kit's orange"
  end

  def test_commercial_weldings_alt_is_untouched
    logo = Navbar.new("welding")
    assert_equal logo.svg(rule: 4, tone: :dark), logo.svg(rule: 4, tone: :dark, colouring: :alt)
    assert_equal %w[#FFFFFF], fills(logo.icon_svg(tone: :dark)), "Alt on dark is still the single-colour helmet"
  end
end
