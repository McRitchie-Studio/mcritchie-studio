# frozen_string_literal: true

# [unit] Logos::PngSizes (task logo-download-card): the PNG size presets a brand page's Download card offers per logo
# type, and the dimension maths behind them: the aspect is kept, every side is a whole pixel, and the rounding is the
# same everywhere (halves up, never below 1).

require "minitest/autorun"
require_relative "../../lib/logos/png_sizes"

class LogosPngSizesTest < Minitest::Test
  PngSizes = Logos::PngSizes

  # Studio's navbar drawing (rule of 4), an icon that is not square, and the widest stacked form.
  NAVBAR = [2560.42, 300.0].freeze
  ICON = [662.45, 538.14].freeze
  STACKED = [2056.97, 1554.18].freeze

  def test_natural_reads_the_root_view_box
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 662.45 538.14" width="662.45" height="538.14"><g viewBox="0 0 1 1"/></svg>)
    assert_equal [662.45, 538.14], PngSizes.natural(svg)
    assert_raises(ArgumentError) { PngSizes.natural("<svg/>") }
    assert_raises(ArgumentError) { PngSizes.natural(%(<svg viewBox="0 0 0 10"/>)) }
  end

  # Alex McRitchie, 2026-10-14 22:35: an icon downloads in its true aspect by default, and as a padded 1:1 square on request.
  def test_the_icon_presets_set_the_long_side_and_keep_the_true_aspect_by_default
    presets = PngSizes.presets(:icon, *ICON)
    assert_equal [16, 32, 48, 64, 180, 192, 256, 512, 1024], presets.map { |preset| preset[:width] }, "the chest is wider than tall"
    assert_equal [512, 416], presets.find { |preset| preset[:key] == "512" }.values_at(:width, :height), "512 × 538.14 / 662.45 = 415.9"
    assert(presets.all? { |preset| preset[:fit] == "fill" }, "no padding")
    assert_equal "512 × 416", presets.find { |preset| preset[:key] == "512" }[:label]
    tall = PngSizes.presets(:icon, 425.06, 481.0)
    assert_equal [452, 512], tall.find { |preset| preset[:key] == "512" }.values_at(:width, :height), "a tall icon: the height is the long side"
  end

  def test_the_square_icon_presets_pad_to_n_by_n_and_name_what_they_serve
    presets = PngSizes.presets(:icon, *ICON, square: true)
    assert_equal [16, 32, 48, 64, 180, 192, 256, 512, 1024], presets.map { |preset| preset[:width] }
    assert(presets.all? { |preset| preset[:width] == preset[:height] && preset[:fit] == "contain" }, "the icon fitted inside a square")
    assert_equal "Apple touch icon", presets.find { |preset| preset[:key] == "180" }[:use]
    assert_equal "Android and PWA icon", presets.find { |preset| preset[:key] == "192" }[:use]
  end

  def test_an_icon_within_one_percent_of_square_is_square_either_way
    assert PngSizes.square?(215.0, 217.0), "Industries"
    refute PngSizes.square?(*ICON)
    assert_equal [[512, 512, "contain"]], PngSizes.presets(:icon, 215.0, 217.0).select { |preset| preset[:key] == "512" }.map { |preset| preset.values_at(:width, :height, :fit) }
  end

  def test_square_means_nothing_for_the_wide_logos
    assert_equal PngSizes.presets(:navbar, *NAVBAR), PngSizes.presets(:navbar, *NAVBAR, square: true)
  end

  def test_the_navbar_presets_keep_the_aspect_in_whole_pixels
    presets = PngSizes.presets(:navbar, *NAVBAR).to_h { |preset| [preset[:key], preset.values_at(:width, :height)] }
    # 400 × 300 / 2560.42 = 46.87 → 47; 800 → 93.73 → 94; 1200 → 140.60 → 141; 2400 → 281.20 → 281.
    assert_equal({ "w400" => [400, 47], "w800" => [800, 94], "w1200" => [1200, 141], "w2400" => [2400, 281],
                   "1x" => [512, 60], "2x" => [1024, 120], "4x" => [2048, 240] }, presets)
  end

  def test_the_stacked_presets_scale_from_the_height_shown_on_the_page
    presets = PngSizes.presets(:stacked, *STACKED).to_h { |preset| [preset[:key], preset.values_at(:width, :height)] }
    assert_equal [400, 302], presets.fetch("w400"), "400 × 1554.18 / 2056.97 = 302.22"
    assert_equal [318, 240], presets.fetch("1x"), "240 × 2056.97 / 1554.18 = 317.64"
    assert_equal [1271, 960], presets.fetch("4x"), "960 × 2056.97 / 1554.18 = 1270.55"
    assert(PngSizes.presets(:stacked, *STACKED).all? { |preset| preset[:fit] == "fill" })
  end

  def test_every_preset_keeps_the_aspect_to_within_one_pixel
    { navbar: NAVBAR, stacked: STACKED }.each do |type, (width, height)|
      PngSizes.presets(type, width, height).each do |preset|
        expected = preset[:width] * height / width
        assert_in_delta expected, preset[:height], 0.5 + 1e-9, "#{type} #{preset[:key]}"
      end
    end
  end

  def test_fit_sets_one_side_and_rounds_the_other_halves_up
    assert_equal [1000, 117], PngSizes.fit(:width, 1000, *NAVBAR)
    assert_equal [4267, 500], PngSizes.fit(:height, 500, *NAVBAR)
    assert_equal [3, 2], PngSizes.fit(:width, 3, 2.0, 1.0), "1.5 rounds up to 2"
    assert_equal [1, 1], PngSizes.fit(:width, 1, *NAVBAR), "never below one pixel"
    assert_equal [100, 50], PngSizes.fit(:width, "100", 2.0, 1.0), "a request string is a whole number"
  end

  def test_fit_refuses_a_side_out_of_range_or_not_whole
    [0, -4, PngSizes::MAX_SIDE + 1].each { |side| assert_raises(ArgumentError) { PngSizes.fit(:width, side, *NAVBAR) } }
    assert_raises(ArgumentError) { PngSizes.fit(:width, "12.5", *NAVBAR) }
    assert_raises(ArgumentError, "10242 wide is past the limit") { PngSizes.fit(:height, 1200, *NAVBAR) }
  end

  def test_a_preset_past_the_largest_side_is_left_out
    tall = PngSizes.presets(:stacked, 100.0, 1000.0)
    assert(tall.all? { |preset| [preset[:width], preset[:height]].max <= PngSizes::MAX_SIDE })
    refute(tall.any? { |preset| preset[:key] == "w2400" }, "2400 wide is 24000 tall here")
  end

  def test_every_type_has_its_default_preset_and_backgrounds_cover_every_tone
    { icon: ICON, navbar: NAVBAR, stacked: STACKED }.each do |type, size|
      assert_includes PngSizes.presets(type, *size).map { |preset| preset[:key] }, PngSizes::DEFAULTS.fetch(type)
    end
    assert_equal %i[light dark watermark], PngSizes::BACKGROUNDS.keys
  end
end
