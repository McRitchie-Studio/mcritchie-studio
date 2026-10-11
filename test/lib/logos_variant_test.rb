# frozen_string_literal: true

# [unit] Logos::Variant (task logo-studio-gallery-page): the gallery's reading
# of URL params into one Navbar Logo, its refusals, its filename and its
# accessible label. Task logo-gallery-context-dropdown adds the page's context
# (the one tone every logo is shown in) and the watermark tone. Task
# logo-tabs-icon-and-stacked adds the logo TYPE: icon, navbar or stacked.

require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"
require_relative "../../lib/logos/variant"

class LogosVariantTest < Minitest::Test
  Variant = Logos::Variant

  def logo = @logo ||= Logos::NavbarLogo.new("industries")
  def stacked = @stacked ||= Logos::StackedLogo.new("industries")
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

  def test_all_lists_one_rules_three_text_versions_in_page_order
    all = Variant.all(logo, rule: 3, tone: :dark, guides: true)
    assert_equal [[:navbar, 3, :homogeneous], [:navbar, 3, :first], [:navbar, 3, :second]], all.map { |v| [v.type, v.rule, v.text] }
    assert_equal [:dark], all.map(&:tone).uniq
    assert all.all?(&:guides)
    assert_equal 3, all.map(&:filename).uniq.size
    assert_equal [[4, :light, false]], Variant.all(logo).map { |v| [v.rule, v.tone, v.guides] }.uniq, "rule of 4, light, without guides, unless asked"
  end

  def test_all_lists_a_stacked_logos_three_text_versions_and_an_icons_one
    all = Variant.all(stacked, type: :stacked, tone: :watermark, guides: true, rule: 3)
    assert_equal [[:stacked, nil, :homogeneous], [:stacked, nil, :first], [:stacked, nil, :second]], all.map { |v| [v.type, v.rule, v.text] }
    assert_equal [[:watermark, true]], all.map { |v| [v.tone, v.guides] }.uniq
    assert_equal stacked.svg(text: :first, tone: :watermark, guides: true), all[1].svg

    icon = Variant.all(logo, type: :icon, tone: :dark, guides: true, rule: 3)
    assert_equal [[:icon, nil, nil, :dark, false]], icon.map { |v| [v.type, v.rule, v.text, v.tone, v.guides] }, "an icon has a tone and nothing else"
    assert_equal logo.icon_svg(tone: :dark), icon.first.svg
  end

  def test_each_type_is_named_and_routed_by_its_own_choices
    icon = Variant.parse(logo, { tone: "dark", rule: "9", text: "third", guides: "yes" }, type: :icon)
    assert_equal [{ tone: :dark }, "industries-icon-dark.svg", "McRitchie Industries icon, dark"], [icon.params, icon.filename, icon.label]
    assert_equal "industries-icon-watermark.svg", Variant.new(logo, type: :icon, tone: :watermark).filename

    first = Variant.parse(stacked, { text: "first", rule: "9" }, type: :stacked)
    assert_equal [{ form: :two_line, text: :first, tone: :light, guides: 0 }, "industries-stacked-two-line-first-light.svg",
                  "McRitchie Industries stacked logo, two lines, first word leads, light"],
                 [first.params, first.filename, first.label]
    assert_equal stacked.svg(text: :first), first.svg
    guides = Variant.parse(stacked, { tone: "dark", guides: "1" }, type: :stacked)
    assert_equal ["industries-stacked-two-line-homogeneous-dark-guides.svg", "McRitchie Industries stacked logo, two lines, homogeneous, dark, construction guides"],
                 [guides.filename, guides.label]
    assert_match(/unknown text "third"/, refusal { Variant.parse(stacked, { text: "third" }, type: :stacked) })
    assert_match(/unknown tone "sepia"/, refusal { Variant.parse(logo, { tone: "sepia" }, type: :icon) })
  end

  def test_a_type_a_context_and_a_rule_are_read_from_a_pages_params
    assert_equal %i[navbar icon navbar stacked], [nil, "icon", "navbar", "stacked"].map { |value| Variant.type(value) }
    assert_equal({ icon: "Icon", navbar: "Navbar Logo", stacked: "Stacked Logo" }, Variant::TYPES)
    assert_equal [4, 3, 4], [nil, "3", "4"].map { |value| Variant.rule(value) }, "a page shows the rule of 4 unless asked"
    ["", "Icon", "submark", ["icon"]].each { |value| assert_match(/unknown type .*: expected one of icon, navbar, stacked/, refusal { Variant.type(value) }) }
    ["", "5", "four", ["4"]].each { |value| assert_match(/unknown rule .*: expected one of 3, 4/, refusal { Variant.rule(value) }) }
  end

  def test_the_logo_that_draws_a_type_and_a_mismatch_is_a_programming_error
    assert_equal [Logos::NavbarLogo, Logos::NavbarLogo, Logos::StackedLogo], %i[icon navbar stacked].map { |type| Variant.logo("turf", type).class }
    assert_instance_of Logos::NavbarLogo, Variant.logo("turf")
    assert_match(/a stacked variant of industries was given a Logos::NavbarLogo/, assert_raises(ArgumentError) { Variant.new(logo, type: :stacked) }.message)
    assert_raises(ArgumentError) { Variant.new(stacked, type: :navbar) }
    assert_raises(ArgumentError) { Variant.new(stacked, type: :icon) }
    assert_match(/unknown type :submark: expected one of icon, navbar, stacked/, refusal { Variant.new(logo, type: :submark) })
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

  # Task stacked-tagline-and-ghost-grid: the Stacked Logo's form.
  def test_a_stacked_form_is_read_named_and_drawn
    tagline = Variant.parse(stacked, { form: "tagline", text: "first" }, type: :stacked)
    assert_equal [:tagline, { form: :tagline, text: :first, tone: :light, guides: 0 }], [tagline.form, tagline.params]
    assert_equal "industries-stacked-tagline-first-light.svg", tagline.filename
    assert_equal "McRitchie Industries stacked logo, with tagline, first word leads, light", tagline.label
    assert_equal stacked.svg(form: :tagline, text: :first), tagline.svg
    welding = Variant.parse(Logos::StackedLogo.new("welding"), { form: "tagline", text: "first", tone: "light" }, type: :stacked)
    assert_equal "welding-stacked-tagline-first-light.svg", welding.filename, "the brief's own example"
    assert_equal "turf-stacked-one-line-homogeneous-light.svg", Variant.parse(Logos::StackedLogo.new("turf"), {}, type: :stacked).filename
    assert_equal :two_line, Variant.parse(stacked, {}, type: :stacked).form, "absent is the brand's own form"

    assert_match(/unknown form "tagline": expected one of one_line/, refusal { Variant.parse(Logos::StackedLogo.new("turf"), { form: "tagline" }, type: :stacked) })
    ["one_line", "three_line", "", "Tagline", ["tagline"]].each do |value|
      assert_match(/unknown form .*: expected one of two_line, tagline/, refusal { Variant.parse(stacked, { form: value }, type: :stacked) }, value.inspect)
    end
    assert_nil Variant.parse(logo, { form: "nonsense" }).form, "a Navbar Logo does not read the form"
    assert_equal({ rule: 3, text: :homogeneous, tone: :light, guides: 0 }, Variant.parse(logo, { form: "tagline" }).params)

    assert_equal %i[tagline tagline tagline], Variant.all(stacked, type: :stacked, form: :tagline).map(&:form)
    assert_equal %i[two_line two_line two_line], Variant.all(stacked, type: :stacked).map(&:form)
    assert_equal [nil, :tagline, :one_line], [nil, "tagline", "one_line"].map { |value| Variant.form(value) }, "off the Stacked tab any form name is carried"
    assert_match(/unknown form "sideways"/, refusal { Variant.form("sideways") })
  end
end
