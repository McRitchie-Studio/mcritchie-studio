# frozen_string_literal: true

# [unit] Logos::IconInk (task stacked-rule-of-three; Alex McRitchie 2026-10-14 12:16: "The icons need to have the margins cleaned
# up so we don't have extra variables when building out the logos and themes"): an icon's box is its ink. It measures
# the ink exactly, trims a padded icon's box to it without touching its paths, and NavbarLogo refuses an icon that
# comes in with a margin.

require "json"
require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"

class LogosIconInkTest < Minitest::Test
  Ink = Logos::IconInk
  Navbar = Logos::NavbarLogo

  # A 10 x 10 square drawn at (5, 7) in a 30 x 40 box: 5 left, 7 top, 15 right and 23 bottom of margin.
  def padded = { "w" => 30, "h" => 40, "layers" => [{ "role" => "primary", "fill_rule" => "nonzero", "d" => "M5,7L15,7L15,17L5,17Z" }] }

  def test_every_shipped_icon_box_is_its_ink
    Navbar.icons.each do |key, icon|
      Ink.margins(icon).each { |side, margin| assert_in_delta 0, margin, Ink::TOLERANCE, "#{key}: #{side} margin" }
    end
    assert_equal 12, Navbar.icons.size
  end

  def test_a_padded_icon_comes_out_trimmed_with_its_paths_untouched
    assert_equal({ left: 5.0, top: 7.0, right: 15.0, bottom: 23.0 }, Ink.margins(padded))
    refute Ink.trimmed?(padded)
    trimmed = Ink.trim(padded)
    assert_equal [10, 10, "translate(-5,-7)"], trimmed.values_at("w", "h", "transform")
    assert_equal padded["layers"], trimmed["layers"], "the paths are byte for byte the same"
    assert_equal({ left: 0.0, top: 0.0, right: 0.0, bottom: 0.0 }, Ink.margins(trimmed))
    assert Ink.trimmed?(trimmed)
    assert_same trimmed, Ink.trim(trimmed), "trimming twice changes nothing"
  end

  def test_the_trim_folds_into_a_leading_translate_and_otherwise_comes_first
    kit = padded.merge("transform" => "translate(-190,-166)", "layers" => [{ "role" => "primary", "d" => "M195,173L205,173L205,183Z" }])
    assert_equal ["translate(-195,-173)", 10, 10], Ink.trim(kit).values_at("transform", "w", "h"), "one translate, as the kit paths carry"
    scaled = Ink.trim(padded.merge("transform" => "scale(2)"))
    assert_equal ["translate(-10,-14) scale(2)", 20, 20], scaled.values_at("transform", "w", "h")
    assert_equal [0.0, 0.0, 20.0, 20.0], Ink.box(scaled)
  end

  def test_the_ink_is_exact_curves_turning_points_and_strokes_included
    curve = { "w" => 10, "h" => 10, "layers" => [{ "role" => "primary", "d" => "M0,0C0,10 10,10 10,0Z" }] }
    assert_equal [0.0, 0.0, 10.0, 7.5], Ink.box(curve), "the curve's lowest point, not its control points"
    stroked = { "w" => 10, "h" => 10, "layers" => [{ "role" => "primary", "paint" => "stroke", "stroke_width" => 2, "d" => "M0,0L10,10" }] }
    assert_equal [-1.0, -1.0, 11.0, 11.0], Ink.box(stroked), "half the stroke past the path"
  end

  def test_what_cannot_be_measured_is_refused
    relative = padded.merge("layers" => [{ "role" => "primary", "d" => "M5,7l10,0l0,10Z" }])
    assert_match(/only in absolute M, L, C and Z path data/, assert_raises(Ink::Error) { Ink.box(relative) }.message)
    assert_match(/no ink to measure/, assert_raises(Ink::Error) { Ink.box(padded.merge("layers" => [])) }.message)
  end

  # Intake: an icon with a margin is never drawn; trimmed, the same icon is.
  def test_navbar_logo_refuses_a_padded_icon_and_draws_it_trimmed
    message = assert_raises(Navbar::Error) { Navbar.new("studio", icons: Navbar.icons.merge("studio" => padded)) }.message
    assert_equal "brand studio: icon studio's box is not its ink (margins left 5, top 7, right 15, bottom 23): trim it with " \
                 "Logos::IconInk.trim (bin/rails logos:trim_icons trims the icon data)", message
    relative = Navbar.icons.merge("studio" => padded.merge("layers" => [{ "role" => "primary", "fill_rule" => "nonzero", "d" => "M5,7l10,0Z" }]))
    assert_match(/brand studio: icon studio: an icon's ink can be measured only in absolute M, L, C and Z/, assert_raises(Navbar::Error) { Navbar.new("studio", icons: relative) }.message)
    logo = Navbar.new("studio", icons: Navbar.icons.merge("studio" => Ink.trim(padded)))
    assert_includes logo.icon_svg, %(viewBox="0 0 10.00 10.00")
  end

  def test_trim_data_rewrites_a_data_file_and_names_what_changed
    json, changed = Ink.trim_data(JSON.generate("padded" => padded, "tight" => Ink.trim(padded)))
    assert_equal %w[padded], changed
    assert_equal({ "padded" => Ink.trim(padded), "tight" => Ink.trim(padded) }, JSON.parse(json))
  end

  # Alex McRitchie 2026-10-14 12:07, on Commercial Welding v2's stacked drawing: "there's some extra space on the right side" of
  # the hood. Its box is its ink now, so in both proportions the hood's ink is centred on the name: equal margins to
  # the name's left and right ink edges, within half a design unit.
  def test_welding_v2s_hood_is_centred_on_its_ink_in_both_proportions
    stacked = Logos::StackedLogo.new("welding_v2")
    icon = Navbar.icons.fetch("welding_v2")
    left, _, right, = Ink.box(icon)
    Logos::StackedLogo::PROPORTIONS.each do |proportion|
      box = stacked.layout(proportion:)
      scale = box.icon_height / icon.fetch("h")
      ink_left = box.icon_left + left * scale
      ink_right = box.icon_left + right * scale
      assert_in_delta ink_left, box.width - ink_right, 0.5, "#{proportion}: the hood's ink is centred on the name"
      assert_in_delta box.icon_width, ink_right - ink_left, 0.5, "#{proportion}: the hood fills its box"
    end
  end
end
