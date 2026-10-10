# frozen_string_literal: true

# [unit] Logos::Variant (task logo-studio-gallery-page): the gallery's reading
# of URL params into one Navbar Logo, its refusals, its filename and its
# accessible label. Task logo-gallery-context-dropdown adds the page's context
# (the one tone every logo is shown in) and the watermark tone.

require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/variant"

class LogosVariantTest < Minitest::Test
  Variant = Logos::Variant

  def logo = @logo ||= Logos::NavbarLogo.new("industries")
  def parse(**params) = Variant.parse(logo, params)
  def refusal(&) = assert_raises(Logos::NavbarLogo::Error, &).message

  def test_params_become_the_librarys_arguments
    variant = parse(rule: "4", text: "second", tone: "dark", guides: "1")
    assert_equal [4, :second, :dark, true], [variant.rule, variant.text, variant.tone, variant.guides]
    assert_equal logo.svg(rule: 4, text: :second, tone: :dark, guides: true), variant.svg
    assert_equal({ rule: 4, text: :second, tone: :dark, guides: 1 }, variant.params)
  end

  def test_an_absent_param_takes_the_librarys_default
    variant = parse
    assert_equal [3, :homogeneous, :light, false], [variant.rule, variant.text, variant.tone, variant.guides]
    assert_equal logo.svg, variant.svg
  end

  def test_a_param_it_does_not_know_is_refused_by_name
    assert_match(/unknown rule "5": expected one of 3, 4/, refusal { parse(rule: "5") })
    assert_match(/unknown rule "4abc"/, refusal { parse(rule: "4abc") })
    assert_match(/unknown rule ""/, refusal { parse(rule: "") })
    assert_match(/unknown rule \["4"\]/, refusal { parse(rule: ["4"]) })
    assert_match(/unknown text "third": expected one of homogeneous, first, second/, refusal { parse(text: "third") })
    assert_match(/unknown tone "sepia": expected one of light, dark, watermark/, refusal { parse(tone: "sepia") })
    assert_match(/unknown guides "true": expected 0 or 1/, refusal { parse(guides: "true") })
    assert_match(/unknown download "yes": expected 0 or 1/, refusal { Variant.flag("yes", "download") })
  end

  def test_the_filename_names_the_brand_and_every_choice
    assert_equal "industries-navbar-rule4-second-light.svg", parse(rule: "4", text: "second", tone: "light").filename
    assert_equal "industries-navbar-rule3-homogeneous-dark-guides.svg", parse(tone: "dark", guides: "1").filename
  end

  def test_the_label_is_the_logos_accessible_name
    assert_equal "McRitchie Industries navbar logo, rule of 4, second word leads, light", parse(rule: "4", text: "second").label
    assert_equal "McRitchie Studio navbar logo, rule of 3, homogeneous, dark, construction guides",
                 Variant.new(Logos::NavbarLogo.new("studio"), rule: 3, text: :homogeneous, tone: :dark, guides: true).label
  end

  def test_all_lists_a_tones_six_logos_in_page_order
    all = Variant.all(logo, tone: :dark, guides: true)
    assert_equal [[3, :homogeneous], [3, :first], [3, :second], [4, :homogeneous], [4, :first], [4, :second]], all.map { |v| [v.rule, v.text] }
    assert_equal [:dark], all.map(&:tone).uniq
    assert all.all?(&:guides)
    assert_equal 6, all.map(&:filename).uniq.size
    assert_equal [[:light, false]], Variant.all(logo).map { |v| [v.tone, v.guides] }.uniq, "light, without guides, unless asked"
  end

  def test_a_pages_context_is_a_tone_light_when_absent_and_refused_when_unknown
    assert_equal %i[light light dark watermark], [nil, "light", "dark", "watermark"].map { |value| Variant.context(value) }
    assert_equal Logos::NavbarLogo::TONES, Variant::CONTEXTS.keys, "the dropdown offers every tone the library draws"
    assert_equal %w[Light Dark Watermark], Variant::CONTEXTS.values
    ["", "Dark", "sepia", "clearspace", ["dark"], { "a" => "dark" }].each do |value|
      assert_match(/unknown context .*: expected one of light, dark, watermark/, refusal { Variant.context(value) }, value.inspect)
    end
  end

  def test_a_watermark_is_named_in_the_params_the_filename_and_the_label
    variant = parse(rule: "4", text: "second", tone: "watermark")
    assert_equal logo.svg(rule: 4, text: :second, tone: :watermark), variant.svg
    assert_equal({ rule: 4, text: :second, tone: :watermark, guides: 0 }, variant.params)
    assert_equal "industries-navbar-rule4-second-watermark.svg", variant.filename
    assert_equal "McRitchie Industries navbar logo, rule of 4, second word leads, watermark", variant.label
    assert_equal "industries-navbar-rule3-homogeneous-watermark-guides.svg", parse(tone: "watermark", guides: "1").filename
  end
end
