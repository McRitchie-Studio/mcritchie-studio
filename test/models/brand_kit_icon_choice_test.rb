# frozen_string_literal: true

require "test_helper"

# [unit] THE KIT'S ICON (task kit-icon-atomic-unit): a brand kit saves ONE icon choice (its colouring and its colour),
# and every Navbar and Stacked Logo the kit draws takes that icon, whatever icon its own choice was saved with; their
# own colouring then governs their words. A kit with no icon saved draws exactly as before.
class BrandKitIconChoiceTest < ActiveSupport::TestCase
  BY = "alex@test.com"

  def params(**given) = ActionController::Parameters.new(given)

  test "the icon choice is stored in the flat URL form, keeping the icon's colour alone" do
    kit = BrandKit.for("studio")
    variant = kit.save_choice(:icon, params(colouring: "alt", icon_colour: "635bb2", first_colour: "8E82FE", rule: "3"), by: BY)
    assert_equal({ "colouring" => "alt", "edits" => { "icon_colour" => "635BB2" } }, kit.reload.icon_choice)
    assert_equal :icon, variant.type
    assert_equal({ icon: { colour: "#635BB2" } }, kit.kit_icon.edits)

    welding = BrandKit.for("welding_v2")
    welding.save_choice(:icon, params(colouring: "original", icon_colour: "D7602E"), by: BY)
    assert_equal({ "colouring" => "original", "edits" => {} }, welding.reload.icon_choice, "an Original shows no edits, so stores none")
  end

  test "an icon choice the brand cannot draw is refused and nothing is stored" do
    assert_raises(Logos::NavbarLogo::Error) { BrandKit.for("studio").save_choice(:icon, params(colouring: "original"), by: BY) }
    assert_raises(Logos::NavbarLogo::Error) { BrandKit.for("studio").save_choice(:icon, params(icon_colour: "000000"), by: BY) }
    assert_nil BrandKit.find_by(brand: "studio")
    error = assert_raises(Logos::NavbarLogo::Error) { BrandKit.variant("studio", :icon, { "colouring" => "alt", "edits" => { "first_colour" => "635BB2" } }) }
    assert_match(/icon choice's edits are the edit params \(icon_colour\)/, error.message)
  end

  test "with no icon saved, a kit draws its logos exactly as before" do
    kit = BrandKit.for("welding_v2")
    kit.save_choice(:stacked, params(form: "tagline", text: "first", colouring: "alt", icon_colour: "D7602E"), by: BY)
    assert_nil kit.kit_icon
    stacked = kit.variant(:stacked, tone: :dark)
    refute_predicate stacked, :own_icon?
    assert_equal Logos::StackedLogo.new("welding_v2").svg(form: :tagline, text: :first, tone: :dark, edits: { icon: { colour: "#D7602E" } }), stacked.svg
    assert_equal({ "form" => "tagline", "text" => "first", "colouring" => "alt", "edits" => { "icon_colour" => "D7602E" } }, kit.stacked_choice,
                 "with no kit icon, a choice keeps its own icon colour")
  end

  # Alex McRitchie's case (2026-10-11 19:23): Commercial Welding v2's Stacked Logo saved in Alt drew the white single-colour
  # helmet beside an Original Navbar and Icon. With the Icon saved in Original, every logo draws the Original helmet.
  test "a saved icon is drawn by every logo, over the icon colour an older choice was saved with" do
    kit = BrandKit.for("welding_v2")
    kit.save_choice(:stacked, params(form: "tagline", text: "first", colouring: "alt", icon_colour: "D7602E"), by: BY)
    kit.save_choice(:icon, params(colouring: "original"), by: BY)
    kit.reload
    %i[light dark].each do |tone|
      stacked = kit.variant(:stacked, tone:)
      assert_equal [:alt, :original], [stacked.colouring, stacked.icon_colouring], tone
      assert_empty stacked.edits, "#{tone}: the old icon colour gives way to the kit's Original icon"
      assert_equal Logos::StackedLogo.new("welding_v2").svg(form: :tagline, text: :first, tone:, icon_colouring: :original), stacked.svg
      navbar = kit.variant(:navbar, tone:)
      assert_equal [:original, :original], [navbar.colouring, navbar.icon_colouring], "#{tone}: the default navbar, in the brand's own colouring"
    end
  end

  test "changing the kit icon changes every logo at once" do
    kit = BrandKit.for("welding_v2")
    kit.save_choice(:navbar, params(rule: "3", text: "second", colouring: "original"), by: BY)
    kit.save_choice(:icon, params(colouring: "alt", icon_colour: "D7602E"), by: BY)
    kit.reload
    navbar = kit.variant(:navbar)
    stacked = kit.variant(:stacked)
    assert_equal [:alt, :alt], [navbar.icon_colouring, stacked.icon_colouring]
    assert_equal [{ icon: { colour: "#D7602E" } }] * 2, [navbar.edits, stacked.edits]
    assert_equal :original, navbar.colouring, "the navbar's words keep their own colouring"
    assert_equal "welding_v2-navbar-rule3-second-light-original-icon-alt-custom.svg", navbar.filename

    kit.clear_choice(:icon, by: BY)
    kit.reload
    refute_predicate kit.variant(:navbar), :own_icon?
    assert_empty kit.variant(:navbar).edits
  end

  # Item 3: a Navbar or Stacked choice saved while the kit has an icon stores no icon colour of its own.
  test "a logo saved under a kit icon keeps no icon colour of its own" do
    kit = BrandKit.for("studio")
    kit.save_choice(:icon, params(colouring: "alt", icon_colour: "8E82FE"), by: BY)
    kit.save_choice(:navbar, params(rule: "4", text: "second", icon_colour: "635BB2", first_colour: "635BB2"), by: BY)
    assert_equal({ "first_colour" => "635BB2" }, kit.reload.navbar_choice["edits"])
    assert_equal({ icon: { colour: "#8E82FE" }, first: { colour: "#635BB2" } }, kit.variant(:navbar).edits)
  end

  test "a tab's defaults carry the kit icon, and a Navbar or Stacked tab's edits are its words' alone" do
    kit = BrandKit.for("studio")
    kit.save_choice(:navbar, params(rule: "3", text: "second", icon_colour: "635BB2", first_colour: "635BB2"), by: BY)
    assert_equal({ icon: { colour: "#635BB2" }, first: { colour: "#635BB2" } }, kit.page_defaults(:navbar)[:edits], "no kit icon: as before")
    kit.save_choice(:icon, params(colouring: "alt", icon_colour: "8E82FE"), by: BY)
    kit.reload
    defaults = kit.page_defaults(:navbar)
    assert_equal({ first: { colour: "#635BB2" } }, defaults[:edits])
    assert_equal({ icon: { colour: "#8E82FE" } }, defaults[:icon].edits)
    assert kit.default_shown?(:navbar, rule: 3, form: nil, colouring: :alt, edits: { first: { colour: "#635BB2" } })
    assert kit.default_shown?(:icon, rule: 4, form: nil, colouring: :alt, edits: { icon: { colour: "#8E82FE" } })
    refute kit.default_shown?(:icon, rule: 4, form: nil, colouring: :alt, edits: {})
    assert_equal({ icon: { colour: "#8E82FE" } }, kit.page_defaults(:icon)[:edits])
  end

  test "an icon choice counts as a saved kit" do
    kit = BrandKit.for("turf")
    kit.save_choice(:icon, params(colouring: "original"), by: BY)
    assert_equal "Kit: saved #{kit.updated_at.strftime('%b %-d, %Y')} by alex", ApplicationController.helpers.logo_kit_status(kit)
  end
end
