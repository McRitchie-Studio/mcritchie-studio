# frozen_string_literal: true

# [unit] Logos::WeldingV2 (task welding-llc-and-v2-helmet): Commercial Welding v2's helmet, derived from v1's traced
# helmet. Alex's item 5: centre the helmet on the line where its two halves meet, and move the lens down so it sits
# on the rule of 3's rows. The lens is shorter than one row, so it is centred on the middle row. Task
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

  def test_each_v2_helmet_is_centred_on_its_own_midline
    PAIRS.each_key do |key|
      icon = v2(key)
      assert_in_delta icon.fetch("w") / 2.0, helmet(key).split, 0.01, "#{key}: the midline is the box's centre, so the vertical guide runs through it"
      assert_in_delta source(key).split + source(key).dx(icon.fetch("w")), helmet(key).split, 0.01, "#{key}: measured again on the moved data"
    end
    assert_equal [443.75, 443.75], ALT.map { |key| v2(key).fetch("w") }, "one box for both Alt tones, as v1 has (426)"
    assert_equal [483, 483], ALT.map { |key| v2(key).fetch("h") }, "the height is v1's"
    assert_equal [892.3, 975], [v2("welding_v2_original").fetch("w"), v2("welding_v2_original").fetch("h")],
                 "the Original's own box, at its own scale: wider than v1's Original (858), as tall (975)"
  end

  def test_the_box_is_widened_not_cropped
    PAIRS.each_key do |key|
      left, top, right, bottom = V2.bbox(parts(v2(key), key).first)
      assert_operator left, :>=, 0, "#{key}: the left ear is inside the box"
      assert_operator right, :<=, v2(key).fetch("w"), "#{key}: the right ear is inside the box"
      assert_operator top, :>=, 0
      assert_operator bottom, :<=, v2(key).fetch("h")
    end
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
      dx = from.dx(v2(key).fetch("w"))
      dy = from.dy
      outer, hole, lens = parts(v1(key), PAIRS.fetch(key)).map { |sub| on_curve(sub) }
      new_outer, new_hole, new_lens = parts(v2(key), key).map { |sub| on_curve(sub) }

      assert_equal shifted(outer, dx, 0), new_outer, "#{key}: the outer helmet only moves across"
      assert_equal shifted(lens, dx, dy), new_lens, "#{key}: the window moves across and down"
      frame, rest = hole.zip(new_hole).partition { |(x, y), _| from.frame?(x, y) }
      assert_operator frame.size, :>, ALT.include?(key) ? 30 : 15, "#{key}: the frame's notch in the white half (the Original's cleaner trace has fewer points)"
      assert_equal shifted(frame.map(&:first), dx, dy), frame.map(&:last), "#{key}: the frame moves with the window, so its band keeps its width"
      assert_equal shifted(rest.map(&:first), dx, 0), rest.map(&:last), "#{key}: the rest of the white half only moves across"
    end
    spark = ->(icon) { V2.subpaths(icon.fetch("layers").find { |l| l["role"] == "accent" }.fetch("d")).map { |sub| V2.bbox(sub) } }
    %w[welding_v2 welding_v2_original].each do |key|
      from = source(key)
      width = v2(key).fetch("w")
      expected = spark.(v1(key)).map { |l, t, r, b| [l, t, r, b].zip([1, 0, 1, 0]).map { |v, across| v + (across == 1 ? from.dx(width) : from.dy) } }
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
    assert_in_delta 443.75 * Navbar::H / 483, logo.layout(rule: 3).icon_width, 1e-9
    %i[light dark].each { |tone| assert_includes logo.icon_svg(tone:, colouring: :original), v2("welding_v2_original").fetch("layers").last.fetch("d"), tone }
  end

  # The Original's layers: the blue silhouette only moves across (it is the outer helmet), the white layer holds the
  # white half and the window (which carry the frame and the lens down), and the spark moves with the lens.
  def test_v2s_original_is_v1s_original_moved_layer_by_layer
    from = source("welding_v2_original")
    blue, white, accent = v2("welding_v2_original").fetch("layers")
    assert_equal %w[blue white accent], [blue, white, accent].map { |layer| layer["role"] }
    assert_equal 1, V2.subpaths(blue.fetch("d")).size, "the silhouette"
    assert_equal 2, V2.subpaths(white.fetch("d")).size, "the white half and the window"
    assert from.split.between?(400, 420), "the midline is where the blue half meets the white, near the square logo's centre (#{from.split})"
    assert_in_delta 47.42, from.dy, 0.01, "about twice v1's Alt move (23.42): the Original is traced at about twice the scale"
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
    assert_match(/expected the white half and the window in the primary layer \(with the outer helmet if it is the primary\), got 2 sub-paths/,
                 refusal { V2.new(two, "x") })
    assert_match(/no primary or white layer/, refusal { V2.new(v1("welding_v2").merge("layers" => []), "x") })
    original = Navbar.icons.fetch("welding_original")
    mixed = original.merge("layers" => original.fetch("layers").map do |layer|
      layer["role"] == "blue" ? layer.merge("d" => layer["d"] + "M1,1L2,1L2,2Z") : layer
    end)
    assert_match(/the blue layer mixes the helmet's halves with other shapes/, refusal { V2.new(mixed, "x").icon })
    assert_match(/cannot hold the helmet centred/, refusal { source("welding_v2").icon(400) })
  end
end
