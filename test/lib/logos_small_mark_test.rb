# frozen_string_literal: true

# [unit] Logos::SmallMark (task footer-stacked-logo; Alex 2026-10-15 08:10, of the old chest-only favicon: "That is the
# correct size"): the favicon's mark is the icon with its specks dropped, derived from the traced data, never drawn.
# It keeps whole islands (with the evenodd holes inside them) and drops every island under MIN_SHARE of the box, its
# box is its ink, and the committed public/favicon-mark.svg is exactly what it derives from the studio icon.

require "json"
require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/small_mark"

class LogosSmallMarkTest < Minitest::Test
  Mark = Logos::SmallMark
  Ink = Logos::IconInk
  ROOT = File.expand_path("../..", __dir__)

  def studio = Logos::NavbarLogo.icons.fetch("studio")
  def subpaths(icon) = icon.fetch("layers").flat_map { |layer| layer.fetch("d").scan(Mark::SUBPATH) }

  # A 100x100 box: a 60x60 square with a 20x20 hole (evenodd), and a 4x4 speck in the corner (0.16% of the box).
  def toy
    { "w" => 100, "h" => 100, "layers" => [{ "fill_rule" => "evenodd",
                                             "d" => "M10,10L70,10L70,70L10,70Z" \
                                                    "M30,30L50,30L50,50L30,50Z" \
                                                    "M95,95L99,95L99,99L95,99Z" }] }
  end

  def test_a_speck_is_dropped_and_a_hole_stays_with_its_island
    mark = Mark.derive(toy)

    assert_equal ["M10,10L70,10L70,70L10,70Z", "M30,30L50,30L50,50L30,50Z"], subpaths(mark)
    assert_equal [60, 60], mark.values_at("w", "h"), "trimmed to the kept island"
    assert Ink.trimmed?(mark)
  end

  def test_the_share_is_a_threshold_of_the_icons_box
    assert_equal 3, subpaths(Mark.derive(toy, min_share: 0.001)).size, "a lower share keeps the speck"
    assert_raises(Mark::Error) { Mark.derive(toy, min_share: 0.9) }
  end

  def test_the_studio_mark_is_the_chest_and_sword_alone
    full = subpaths(studio)
    mark = Mark.derive(studio)
    kept = subpaths(mark)

    assert_empty kept - full, "every kept subpath is the traced data, written back as it was read"
    assert_operator kept.size, :<, full.size, "the specks are gone"
    assert Ink.trimmed?(mark), "its box is its ink"
    # The sparkles, side dashes and loose coins set the full icon's box; without them it is the chest's.
    assert_operator mark["w"].to_f, :<, studio["w"].to_f * 0.85
    assert_operator mark["h"].to_f, :<, studio["h"].to_f * 0.95
    # Each dropped island was small: nothing a 64 px tile would show as more than a speck.
    dropped = full - kept
    box_area = studio["w"].to_f * studio["h"].to_f
    dropped.each do |subpath|
      box = Ink.box({ "w" => studio["w"], "h" => studio["h"], "transform" => studio["transform"], "layers" => [{ "d" => subpath }] })
      assert_operator (box[2] - box[0]) * (box[3] - box[1]), :<, Mark::MIN_SHARE * box_area
    end
  end

  def test_the_favicon_crop_is_a_square_centred_across_the_body_and_standing_on_it
    mark = Mark.derive(toy)  # body: the 60x60 square at 0..60 in the trimmed box
    crop = Mark.crop(mark)

    assert_equal [49.2, 49.2], crop.values_at("w", "h"), "CROP_SIDE of the body's width"
    left, top, right, bottom = Ink.box(crop)
    assert_in_delta(-5.4, left, 0.01)
    assert_in_delta 54.6, right, 0.01, "overhangs both sides equally: centred across"
    assert_in_delta 49.2, bottom, 0.01, "the body's bottom is the tile's"
    assert_in_delta(-10.8, top, 0.01)
    assert_equal subpaths(mark), subpaths(crop), "only the box moves"
  end

  def test_the_committed_favicon_mark_is_what_the_studio_icon_derives
    fill = File.read(File.join(ROOT, "public/brand/icon-dark.svg"))[/ fill="(#\h{3,8})"/, 1]

    assert_equal Mark.svg(Mark.crop(Mark.derive(studio)), fill:), File.read(File.join(ROOT, "public/favicon-mark.svg")),
                 "public/favicon-mark.svg is stale: run bin/rails logos:favicon_mark BRAND=studio, then script/brand_png.cjs"
  end
end
