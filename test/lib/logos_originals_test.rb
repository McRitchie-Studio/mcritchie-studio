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
    assert_equal [857.98, 973.84], [icon["w"], icon["h"]], "cropped to the helmet's ink (858 x 975 before its box was trimmed, Logos::IconInk)"
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

  # v2's Original is v1's with the v2 derivation (Logos::WeldingV2): its own icon, v1's Original colours.
  def test_welding_v2s_original_carries_the_lens_move_in_its_ink_box
    logo = Navbar.new("welding_v2")
    icon = Navbar.icons.fetch("welding_v2_original")
    assert_match(/derived from 'welding_original' by Logos::WeldingV2/, icon["source"])
    %i[light dark].each do |tone|
      svg = logo.icon_svg(tone:, colouring: :original)
      assert_equal %w[#2E5E8E #FFFFFF #D5752B], fills(svg), tone
      # Its box is its ink (task stacked-rule-of-three): v2's widened, midline-centred box (892.30 wide) is gone.
      assert_includes svg, %(viewBox="0 0 857.98 973.84"), "#{tone}: the helmet's ink box"
    end
    assert_equal Navbar.new("welding").svg(rule: 3, text: :first, colouring: :original).scan(/fill="([^"]+)"/).flatten.uniq,
                 logo.svg(rule: 3, text: :first, colouring: :original).scan(/fill="([^"]+)"/).flatten.uniq, "v1's Original colours"
  end

  # Turf Monster's original is the three-colour head trace, in both tones, with its ink (or white) and green name.
  def test_turf_monsters_original_is_the_three_colour_head
    logo = Navbar.new("turf")
    { light: "#1A1535", dark: "#FFFFFF" }.each do |tone, ink|
      icon = logo.icon_svg(tone:, colouring: :original)
      assert_equal %w[#1A550D #5C972A #F0EBCF], fills(icon), "#{tone}: outline, body and light"
      assert_equal %w[#1A550D #5C972A #F0EBCF #4BAF50] + [ink], fills(logo.svg(rule: 3, text: :first, tone:, colouring: :original)), tone
    end
  end

  def test_commercial_weldings_alt_keeps_the_blue_half_on_dark
    logo = Navbar.new("welding")
    assert_equal logo.svg(rule: 4, tone: :dark), logo.svg(rule: 4, tone: :dark, colouring: :alt)
    # Alex McRitchie 2026-10-28: "lets add the blue to both": the Original's trace in the kit's colours.
    assert_equal %w[#2D5E8E #FFFFFF #D7602E], fills(logo.icon_svg(tone: :dark)), "Alt on dark: blue half, white half, orange spark"
    assert_equal %w[#2D5E8E #FFFFFF #D7602E], fills(Navbar.new("welding_v2").icon_svg(tone: :dark)), "v2 too"
    assert_equal 1, fills(logo.icon_svg(tone: :watermark)).size, "the watermark stays one colour"
  end
end
