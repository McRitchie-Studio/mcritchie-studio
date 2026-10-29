# frozen_string_literal: true

require "test_helper"

# [unit] Logos::MotionPreset (task logo-motion-presets): the eight presets Alex McRitchie picked on Logo Motion Lab II,
# which brands can play each, how a motion choice is checked, and the accent a preset's particles are drawn in.
class LogosMotionPresetTest < ActiveSupport::TestCase
  BRANDS = %w[studio industries turf welding welding_v2].freeze

  test "the eight picked presets, in the Motion tab's order, each with the idea it came from" do
    assert_equal %i[pop_slide stack_build match_cut shape_morph tracking_breath dots_to_mark particle_resolve weight_flick],
                 Logos::MotionPreset::ALL.map(&:key)
    assert_equal %w[I1 I2 I16 I22 I23 I18 I8 I17], Logos::MotionPreset::ALL.map(&:idea)
    assert(Logos::MotionPreset::ALL.all? { |preset| preset.title.present? && preset.note.present? })
  end

  test "Weight flick is offered only where the lettering has weights: never on Commercial Welding's traced name" do
    assert_equal %w[studio industries turf], BRANDS.select { |brand| Logos::MotionPreset.for(brand).map(&:key).include?(:weight_flick) }
    BRANDS.each { |brand| assert_equal 7, Logos::MotionPreset.for(brand).count { |preset| !preset.needs_weights? }, brand }
  end

  test "check stores a choice in one spelling and refuses an unknown preset, an unknown logo, or a preset the brand cannot play" do
    assert_equal({ "preset" => "pop_slide", "logo" => "stacked" }, Logos::MotionPreset.check("turf", preset: :pop_slide, logo: :stacked))
    assert_equal({ "preset" => "weight_flick", "logo" => "navbar" }, Logos::MotionPreset.check("studio", preset: "weight_flick", logo: "navbar"))

    assert_match(/unknown motion preset "spin"/, assert_raises(Logos::NavbarLogo::Error) { Logos::MotionPreset.check("turf", preset: "spin", logo: "stacked") }.message)
    assert_match(/plays on navbar or stacked, not "icon"/, assert_raises(Logos::NavbarLogo::Error) { Logos::MotionPreset.check("turf", preset: "pop_slide", logo: "icon") }.message)
    assert_match(/needs lettering with weights/, assert_raises(Logos::NavbarLogo::Error) { Logos::MotionPreset.check("welding", preset: "weight_flick", logo: "stacked") }.message)
  end

  test "check_choice reads a stored choice and refuses any other shape" do
    assert_equal({ "preset" => "match_cut", "logo" => "navbar" }, Logos::MotionPreset.check_choice("industries", { "preset" => "match_cut", "logo" => "navbar" }))
    [nil, "pop_slide", { "preset" => "pop_slide" }, { "preset" => "pop_slide", "logo" => "stacked", "speed" => 2 }].each do |bad|
      assert_raises(Logos::NavbarLogo::Error, bad.inspect) { Logos::MotionPreset.check_choice("turf", bad) }
    end
  end

  test "the accent is the tone's named accent, else the palette's most saturated colour" do
    assert_equal "#4BAF50", Logos::MotionPreset.accent("turf")
    assert_equal "#D7602E", Logos::MotionPreset.accent("welding", :light)
    assert_equal "#8E82FE", Logos::MotionPreset.accent("studio"), "Studio names no accent: its Violet is its most saturated colour"
    BRANDS.each { |brand| assert_match(Logos::NavbarLogo::HEX, Logos::MotionPreset.accent(brand)) }
  end
end
