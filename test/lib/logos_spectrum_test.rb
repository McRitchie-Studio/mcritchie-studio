# frozen_string_literal: true

# [unit] Logos::Spectrum (task brand-colour-spectrum-ramps): each palette colour's 50-950 OKLCH ramp, the brand's hex
# unchanged on its nearest step, and the ramps as CSS tokens.

require "minitest/autorun"
require_relative "../../lib/logos/spectrum"

class LogosSpectrumTest < Minitest::Test
  Spectrum = Logos::Spectrum

  def spectrum(brand) = Spectrum.new(Logos::BrandKit.new(brand))
  def ramp(brand, name) = spectrum(brand).ramps.find { |ramp| ramp.name == name }
  def hexes(brand, name) = ramp(brand, name).steps.map(&:hex)

  def test_every_brand_colour_gets_eleven_steps_with_its_own_hex_on_exactly_one
    Logos::BrandKit.all.each do |kit|
      Spectrum.new(kit).ramps.zip(kit.palette).each do |ramp, swatch|
        assert_equal Spectrum::STEPS, ramp.steps.map(&:step), "#{kit.brand} #{ramp.name}"
        assert_equal [swatch.hex.upcase], ramp.steps.select(&:anchor?).map(&:hex), "#{kit.brand} #{ramp.name}"
        assert ramp.steps.all? { |step| step.hex.match?(/\A#[0-9A-F]{6}\z/) }, "#{kit.brand} #{ramp.name}"
      end
    end
  end

  def test_each_ramp_runs_light_to_dark
    Logos::BrandKit.all.each do |kit|
      Spectrum.new(kit).ramps.each do |ramp|
        lightness = ramp.steps.map { |step| Spectrum.oklch(step.hex).first }
        assert_equal lightness.sort.reverse, lightness, "#{kit.brand} #{ramp.name}"
      end
    end
  end

  # The ramps Alex McRitchie approved in chat on 2026-10-25, byte for byte.
  def test_welding_v2_matches_the_approved_ramps
    assert_equal %w[#F1F8FF #DDEDFF #BDDDFF #A0C5EC #7FA9D4 #618FBD #4575A5 #2D5E8E #194772 #0A345A #002444], hexes("welding_v2", "Welding Blue")
    assert_equal %w[#FFF4F0 #FFE5DB #FECCBA #FEA988 #F47F50 #D7602E #B84B1A #97380A #762801 #591D02 #3F1201], hexes("welding_v2", "Spark Orange")
    assert_equal 700, ramp("welding_v2", "Welding Blue").anchor.step
    assert_equal 500, ramp("welding_v2", "Spark Orange").anchor.step
    assert_equal 400, ramp("welding_v2", "Ember").anchor.step
  end

  def test_white_is_a_neutral_leaning_to_the_brands_lead_hue
    white = ramp("welding_v2", "White")
    assert_equal 50, white.anchor.step
    blue_hue = Spectrum.oklch("#2D5E8E").last
    white.steps.reject(&:anchor?).each do |step|
      _, chroma, hue = Spectrum.oklch(step.hex)
      assert_in_delta 0.012, chroma, 0.004, step.step
      assert_in_delta blue_hue, hue, 0.15, "step #{step.step} leans to Welding Blue"
    end
  end

  def test_a_grey_keeps_its_own_hue
    gunmetal_hue = Spectrum.oklch("#59606A").last
    ramp("industries", "Gunmetal").steps.each { |step| assert_in_delta gunmetal_hue, Spectrum.oklch(step.hex).last, 0.2, step.step }
  end

  def test_each_step_names_its_better_text_and_contrast
    steps = ramp("welding_v2", "Welding Blue").steps
    assert_equal "#000000", steps.first.text
    assert_equal "#FFFFFF", steps.last.text
    blue = steps.find(&:anchor?)
    assert_equal 6.8, blue.contrast
    assert_equal "AA", blue.grade
    assert_in_delta Spectrum.contrast("#2D5E8E", "#FFFFFF"), blue.contrast, 0.05
  end

  def test_a_three_digit_hex_anchors_as_its_six_digit_form
    styles = { "kit" => Logos::NavbarLogo.styles.fetch("studio").merge("palette" => [{ "name" => "Blue", "hex" => "#36c" }]) }
    ramp = Spectrum.new(Logos::BrandKit.new("kit", styles:)).ramps.first
    assert_equal "#3366CC", ramp.hex
    assert_equal ["#3366CC"], ramp.steps.select(&:anchor?).map(&:hex)
  end

  def test_css_names_every_step_by_brand_colour_and_step
    css = spectrum("welding_v2").css
    assert_includes css, "  --welding-v2-welding-blue-700: #2D5E8E;"
    assert_includes css, "  --welding-v2-spark-orange-50: #FFF4F0;"
    assert_equal 4 * 11, css.scan(/^  --/).size
  end
end
