# frozen_string_literal: true

# [unit] Logos::Variant's reading of the edit panel's URL params (task logo-part-editor): EDIT_PARAMS into the
# library's edits and back, which edits a logo shows (none on the icon or a watermark, the tagline's only in the
# tagline form), and an edited logo's download and copy: its SVG, its params, its `-custom` filename and its label.

require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"
require_relative "../../lib/logos/variant"

class LogosVariantEditsTest < Minitest::Test
  Variant = Logos::Variant

  def navbar = @navbar ||= Logos::NavbarLogo.new("studio")
  def stacked = @stacked ||= Logos::StackedLogo.new("studio")
  def refusal(&) = assert_raises(Logos::NavbarLogo::Error, &).message

  def test_edit_params_read_into_edits_and_back
    params = { first_colour: "635bb2", first_weight: "600", ending_colour: "#1A1535", tagline_visible: "0", tagline_weight: "", icon_colour: nil }
    edits = Variant.edits(params)
    assert_equal({ first: { colour: "#635BB2", weight: 600 }, ending: { colour: "#1A1535" }, tagline: { visible: false } }, edits)
    assert_equal({ first_colour: "635BB2", first_weight: 600, ending_colour: "1A1535", tagline_visible: 0 }, Variant.edit_params(edits))
    assert_equal({}, Variant.edits({}))
    assert_equal({}, Variant.edit_params({}))
  end

  def test_edit_params_refuse_what_is_not_a_hex_a_weight_or_a_flag
    assert_equal 'unknown first_colour "violet": expected a six-digit hex', refusal { Variant.edits({ first_colour: "violet" }) }
    assert_match(/unknown icon_colour "#FFF"/, refusal { Variant.edits({ icon_colour: "#FFF" }) })
    assert_equal 'unknown ending_weight "bold": expected a weight such as 300', refusal { Variant.edits({ ending_weight: "bold" }) }
    assert_equal 'unknown tagline_visible "yes": expected 0 or 1', refusal { Variant.edits({ tagline_visible: "yes" }) }
  end

  def test_an_edited_logo_draws_downloads_and_names_its_edits
    variant = Variant.parse(stacked, { form: "tagline", text: "first", first_colour: "635BB2", tagline_visible: "0" }, type: :stacked)
    assert_predicate variant, :edited?
    assert_equal stacked.svg(form: :tagline, text: :first, edits: { first: { colour: "#635BB2" }, tagline: { visible: false } }), variant.svg
    assert_includes variant.svg, %(fill="#635BB2")
    assert_equal({ form: :tagline, text: :first, tone: :light, guides: 0, first_colour: "635BB2", tagline_visible: 0 }, variant.params)
    assert_equal "studio-stacked-tagline-first-light-custom.svg", variant.filename
    # Task logo-gallery-polish-pass, item 3: the tagline is hidden, so the name says so.
    assert_equal "McRitchie Studio stacked logo, tagline hidden, first word leads, light, edited", variant.label
    shown = Variant.parse(stacked, { form: "tagline", text: "first", first_colour: "635BB2" }, type: :stacked)
    assert_equal "McRitchie Studio stacked logo, with tagline, first word leads, light, edited", shown.label
    watermark = Variant.parse(stacked, { form: "tagline", text: "first", tone: "watermark", tagline_visible: "0" }, type: :stacked)
    assert_equal "McRitchie Studio stacked logo, with tagline, first word leads, watermark", watermark.label, "a watermark draws no edits, so its tagline shows"

    navbar_variant = Variant.parse(navbar, { rule: "4", ending_weight: "300" })
    assert_equal "studio-navbar-rule4-homogeneous-light-custom.svg", navbar_variant.filename
    assert_equal navbar.svg(rule: 4, edits: { ending: { weight: 300 } }), navbar_variant.svg
  end

  def test_an_unedited_logo_keeps_its_name_params_and_drawing
    variant = Variant.parse(navbar, { rule: "4", text: "second" })
    refute_predicate variant, :edited?
    assert_equal "studio-navbar-rule4-second-light.svg", variant.filename
    assert_equal({ rule: 4, text: :second, tone: :light, guides: 0 }, variant.params)
    assert_equal navbar.svg(rule: 4, text: :second), variant.svg
  end

  def test_a_logo_shows_only_the_edits_that_reach_it
    edits = { icon: { colour: "#8E82FE" }, tagline: { visible: false } }
    assert_equal({ icon: { colour: "#8E82FE" } }, Variant.new(stacked, type: :stacked, form: :two_line, edits:).edits, "no tagline in two lines")
    assert_equal({ icon: { colour: "#8E82FE" } }, Variant.new(navbar, edits:).edits, "a navbar logo has no tagline")
    assert_equal edits, Variant.new(stacked, type: :stacked, form: :tagline, edits:).edits
    assert_equal({ icon: { colour: "#8E82FE" } }, Variant.new(navbar, type: :icon, edits:).edits, "the icon tab takes its own colour only (the kit icon)")
    watermark = Variant.new(navbar, rule: 4, tone: :watermark, edits:)
    assert_empty watermark.edits, "a watermark is one colour"
    assert_equal navbar.svg(rule: 4, tone: :watermark), watermark.svg
    refute_includes watermark.filename, "custom"
  end

  def test_edits_are_checked_even_where_they_are_not_shown
    assert_match(/palette/, refusal { Variant.new(navbar, type: :icon, edits: { first: { colour: "#000000" } }) })
    assert_match(/no tagline to edit/, refusal { Variant.new(Logos::NavbarLogo.new("turf"), edits: { tagline: { visible: false } }) })
  end
end
