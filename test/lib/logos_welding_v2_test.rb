# frozen_string_literal: true

# [unit] Logos::WeldingV2 (task welding-llc-and-v2-helmet): Commercial Welding v2's helmet, derived from v1's traced
# helmet. Alex McRitchie's item 5: move the lens down so it sits on the rule of 3's rows. (Item 5 also centred the helmet on the
# line where its two halves meet, in a widened box; task stacked-rule-of-three retired that when every icon's box
# became its ink, Logos::IconInk.) The lens is shorter than one row, so it is centred on the middle row. Task
# logo-original-and-alt: the same derivation, run on v1's Original (the traced square logo), gives v2's Original.

require "json"
require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/welding_v2"

class LogosWeldingV2Test < Minitest::Test
  V2 = Logos::WeldingV2
  Navbar = Logos::NavbarLogo
  PAIRS = { "welding_v2" => "welding", "welding_v2_mono" => "welding_mono", "welding_v2_original" => "welding_original" }.freeze
  ALT = %w[welding_v2 welding_v2_mono].freeze

  def v1(key) = Navbar.icons.fetch(PAIRS.fetch(key))
  def v2(key) = Navbar.icons.fetch(key)
  def helmet(key) = V2.new(v2(key), key)
  def source(key) = V2.new(v1(key), PAIRS.fetch(key))
  def refusal(&) = assert_raises(V2::Error, &).message

  # Each primary sub-path's on-curve points, by role: [outer, white half, window].
  def parts(icon, from)
    helmet = V2.new(icon, from)
    %i[@outer @hole @lens].map { |name| helmet.instance_variable_get(name) }
  end

  def on_curve(subpath) = subpath.filter_map { |_, points| points.last }
  def shifted(points, dx, dy) = points.map { |x, y| [(x + dx).round(2), (y + dy).round(2)] }

  def test_the_shipped_data_is_exactly_what_the_derivation_writes
    assert_equal File.read(V2::FILE), V2.json, "run `bin/rails logos:welding_v2` after changing Logos::WeldingV2 or v1's helmet"
  end

  # Task stacked-rule-of-three (Alex McRitchie 2026-10-14 12:07: "there's some extra space on the right side" of the hood): each
  # v2 helmet's box is its ink, the outer helmet flush with it on every side, so its ink margins left and right are
  # equal (both zero) and the hood is centred on its ink wherever a logo centres its box.
  def test_each_v2_helmet_is_flush_with_its_box
    PAIRS.each do |key, from|
      icon = v2(key)
      margins = Logos::IconInk.margins(icon)
      assert_in_delta margins[:left], margins[:right], 0.5, "#{key}: the ink's left and right margins are equal"
      margins.each { |side, margin| assert_in_delta 0, margin, 0.02, "#{key}: flush #{side}" }
      left, top, right, bottom = V2.bbox(parts(icon, key).first)
      assert_in_delta 0, left, 0.02, "#{key}: the left ear is the box's left edge"
      assert_in_delta icon.fetch("w"), right, 0.02, "#{key}: the right ear is the box's right edge"
      assert_in_delta 0, top, 0.02
      assert_in_delta icon.fetch("h"), bottom, 0.02
      assert_equal [v1(key).fetch("w"), v1(key).fetch("h")], [icon.fetch("w"), icon.fetch("h")], "#{key}: v1's #{from} ink box: the lens moves inside it"
    end
    assert_equal [[425.06, 481], [425.54, 482.74], [857.98, 973.84]], PAIRS.keys.map { |key| [v2(key).fetch("w"), v2(key).fetch("h")] },
                 "was 443.75 x 483 (both Alt) and 892.3 x 975, widened to centre the midline"
  end

  def test_each_v2_lens_is_centred_on_the_rule_of_3s_middle_row
    PAIRS.each_key do |key|
      row = v2(key).fetch("h") / 3.0
      _, top, _, bottom = helmet(key).window
      _, was_top, _, was_bottom = source(key).window
      assert_in_delta was_bottom - was_top, bottom - top, 0.01, "#{key}: the lens keeps its shape"
      assert_operator bottom - top, :<, row, "#{key}: the lens is shorter than one row (#{(bottom - top).round(2)} of #{row.round(2)}), so it is centred"
      assert_in_delta 1.5 * row, (top + bottom) / 2, 0.01, "#{key}: the lens's centre is the middle row's centre"
      assert_in_delta top - row, 2 * row - bottom, 0.02, "#{key}: equal space above and below it inside the row"
      assert_operator top, :>, row
      assert_operator bottom, :<, 2 * row
      assert_operator top - was_top, :>, 0, "#{key}: the lens moved DOWN"
    end
  end

  def test_the_spark_moves_with_the_window_and_the_frame_follows
    PAIRS.each_key do |key|
      from = source(key)
      dx = 0
      dy = from.dy
      outer, hole, lens = parts(v1(key), PAIRS.fetch(key)).map { |sub| on_curve(sub) }
      new_outer, new_hole, new_lens = parts(v2(key), key).map { |sub| on_curve(sub) }

      assert_equal shifted(outer, dx, 0), new_outer, "#{key}: the outer helmet does not move"
      assert_equal shifted(lens, dx, dy), new_lens, "#{key}: the window moves across and down"
      frame, rest = hole.zip(new_hole).partition { |(x, y), _| from.frame?(x, y) }
      assert_operator frame.size, :>, ALT.include?(key) ? 30 : 15, "#{key}: the frame's notch in the white half (the Original's cleaner trace has fewer points)"
      assert_equal shifted(frame.map(&:first), dx, dy), frame.map(&:last), "#{key}: the frame moves with the window, so its band keeps its width"
      assert_equal shifted(rest.map(&:first), dx, 0), rest.map(&:last), "#{key}: the rest of the white half does not move"
    end
    spark = ->(icon) { V2.subpaths(icon.fetch("layers").find { |l| l["role"] == "accent" }.fetch("d")).map { |sub| V2.bbox(sub) } }
    %w[welding_v2 welding_v2_original].each do |key|
      from = source(key)
      offset = V2.offset(v1(key)["transform"], key)
      expected = spark.(v1(key)).map { |l, t, r, b| [l + offset[0], t + offset[1] + from.dy, r + offset[0], b + offset[1] + from.dy] }
      spark.(v2(key)).flatten.zip(expected.flatten).each { |got, want| assert_in_delta want, got, 0.011, "#{key}: the orange spark moves with the window" }
    end
  end

  def test_the_v2_brand_draws_its_own_helmet_and_v1s_name
    logo = Navbar.new("welding_v2")
    assert_equal %w[COMMERCIAL WELDING], logo.words
    assert_equal "Commercial Welding v2", logo.title
    { light: "welding_v2", dark: "welding_v2_mono", watermark: "welding_v2_mono" }.each do |tone, key|
      assert_includes logo.icon_svg(tone:), v2(key).fetch("layers").first.fetch("d"), tone
    end
    assert_in_delta 425.06 * Navbar::H / 481, logo.layout(rule: 3).icon_width, 1e-9
    %i[light dark].each { |tone| assert_includes logo.icon_svg(tone:, colouring: :original), v2("welding_v2_original").fetch("layers").last.fetch("d"), tone }
  end

  # The Original's layers: the blue silhouette only moves across (it is the outer helmet), the white layer holds the
  # white half and the window (which carry the frame and the lens down), and the spark moves with the lens.
  def test_v2s_original_is_v1s_original_moved_layer_by_layer
    from = source("welding_v2_original")
    blue, white, accent = v2("welding_v2_original").fetch("layers")
    assert_equal %w[blue white accent], [blue, white, accent].map { |layer| layer["role"] }
    assert_equal 2, V2.subpaths(blue.fetch("d")).size, "the silhouette, with the window cut out of it"
    assert_equal 1, V2.subpaths(white.fetch("d")).size, "the white half alone: the window is no longer white"
    assert_in_delta 47.44, from.dy, 0.01, "about twice v1's Alt move (23.42): the Original is traced at about twice the scale"
  end

  def test_curve_turning_points_count_in_a_bounding_box
    assert_equal [0.0, 0.0, 10.0, 7.5], V2.bbox(V2.subpaths("M0.00,0.00C0.00,10.00 10.00,10.00 10.00,0.00Z").first)
    d = v1("welding_v2").fetch("layers").first.fetch("d")
    assert_equal d, V2.subpaths(d).map { |sub| V2.serialise(sub) }.join, "reading and writing the traced data loses nothing"
  end

  def test_what_it_cannot_move_is_refused
    assert_match(/only absolute M, L, C and Z/, refusal { V2.subpaths("M0,0 l10,10Z") })
    assert_match(/only absolute M, L, C and Z/, refusal { V2.subpaths("M0,0 Q5,5 10,0Z") })
    two = v1("welding_v2").merge("layers" => [{ "role" => "primary", "fill_rule" => "evenodd", "d" => "M0,0L10,0L10,10ZM2,2L4,2L4,4Z" }])
    assert_match(/expected the white half and the window in the primary layer \(the window may be a hole in the outer helmet's\), got 1 shapes besides/,
                 refusal { V2.new(two, "x") })
    assert_match(/no primary or white layer/, refusal { V2.new(v1("welding_v2").merge("layers" => []), "x") })
    original = Navbar.icons.fetch("welding_original")
    mixed = original.merge("layers" => original.fetch("layers").map do |layer|
      layer["role"] == "blue" ? layer.merge("d" => layer["d"] + "M1,1L2,1L2,2Z") : layer
    end)
    assert_match(/expected the white half and the window in the white layer .*got 3 shapes besides the outer helmet/, refusal { V2.new(mixed, "x") })
    assert_match(/welding: only a translate can be read, got transform "scale\(2\)"/, refusal { V2.new(v1("welding_v2").merge("transform" => "scale(2)"), "welding") })
  end

  # Task kit-export-and-clear-lens (Alex McRitchie 2026-10-12 00:55: "remove the white of the lens so I can see it clear"): v2's
  # Original window is a hole in the blue silhouette (even-odd), not an opaque white shape, so the page shows through.
  def test_v2s_original_lens_is_see_through
    blue, white = v2("welding_v2_original").fetch("layers").first(2).map { |layer| V2.subpaths(layer.fetch("d")) }
    window = helmet("welding_v2_original").window
    assert_equal "evenodd", v2("welding_v2_original").fetch("layers").first.fetch("fill_rule"), "even-odd: the second sub-path is a hole"
    assert_equal window, V2.bbox(blue.last), "the silhouette's second sub-path is the window: a hole in the blue"
    refute white.any? { |sub| V2.bbox(sub) == window }, "the white layer no longer paints the window"
    assert_equal 1, white.size, "the opaque white right half stays: it holds the helmet on a dark page"
    assert_includes v2("welding_v2_original").fetch("source"), "see-through"
  end

  def test_v1s_original_and_v2s_alt_are_untouched
    assert_equal 2, V2.subpaths(v1("welding_v2_original").fetch("layers")[1].fetch("d")).size, "v1's Original keeps its white window: Alex McRitchie asked for the new logo only"
    ALT.each do |key|
      layers = v2(key).fetch("layers")
      assert_equal 3, V2.subpaths(layers.first.fetch("d")).size, "#{key}: its primary already held the window as a hole"
      refute_includes v2(key).fetch("source"), "see-through", "#{key}: its note is unchanged"
    end
  end

  # The derivation reads its own output back: v2's Original, window and all, is found exactly as v1's is.
  def test_the_cleared_original_reads_back
    from = source("welding_v2_original")
    again = helmet("welding_v2_original")
    assert_equal from.window.zip([0, from.dy] * 2).map { |v, d| (v + d).round(2) }, again.window.map { |v| v.round(2) }
    assert_in_delta 0, again.dy, 0.01, "read back, the lens is already centred on the middle row"
  end
end
