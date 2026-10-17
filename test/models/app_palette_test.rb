require "test_helper"
require_relative "../support/client_cto_fixtures"

# [unit] AppPalette: the client's colour scheme is a theme only when every key
# of both modes is a #RRGGBB hex and its text reads on its surface (WCAG AA).
class AppPaletteTest < ActiveSupport::TestCase
  PALETTE = ClientCtoFixtures::PALETTE

  test "a complete, readable palette passes and normalizes to upcased string keys" do
    assert AppPalette.valid?(PALETTE)
    lower = { light: PALETTE["light"].transform_values(&:downcase), dark: PALETTE["dark"] }
    assert_equal PALETTE, AppPalette.normalize(lower)
  end

  test "a missing key, a non-hex value or a missing mode is refused, naming the mode" do
    no_accent = PALETTE.deep_dup.tap { |p| p["light"].delete("accent") }
    assert_match(/light needs accent/, AppPalette.errors(no_accent).join)
    named = PALETTE.deep_dup.tap { |p| p["dark"]["primary"] = "indigo" }
    assert_match(/dark needs primary/, AppPalette.errors(named).join)
    assert_match(/dark needs/, AppPalette.errors(PALETTE.slice("light")).join)
    refute AppPalette.valid?(nil)
    refute AppPalette.valid?("not a palette")
  end

  test "text that does not read on its surface is refused with its ratio" do
    grey = PALETTE.deep_dup.tap { |p| p["light"]["text"] = "#BBBBBB" }
    assert_match(%r{light text on surface is 1\.\d+:1, under 4\.5:1}, AppPalette.errors(grey).join)
  end

  test "contrast is the WCAG ratio and the triplet feeds rgb(var(--x) / a)" do
    assert_in_delta 21.0, AppPalette.contrast("#000000", "#FFFFFF"), 0.01
    assert_equal "79 70 229", AppPalette.rgb_triplet("#4F46E5")
    assert_nil AppPalette.rgb_triplet("red")
  end
end
