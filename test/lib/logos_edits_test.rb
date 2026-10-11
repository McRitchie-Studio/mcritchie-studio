# frozen_string_literal: true

# [unit] The operator's per-part edits (task logo-part-editor, Alex's item 4b): Logos::NavbarLogo and
# Logos::StackedLogo take `edits:` for the icon, the first word, the ending and the tagline. A colour comes from the
# brand's palette, a weight from EDIT_WEIGHTS (never for traced lettering), and the tagline can be hidden. Geometry
# never moves except as a weight changes a word's width. No edits draws exactly what it drew before (the byte pins in
# logos_navbar_logo_test.rb and logos_stacked_logo_test.rb hold that for the shipped data; this file holds it for
# the `edits:` spelling of "none").

require "minitest/autorun"
require "nokogiri"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"

class LogosEditsTest < Minitest::Test
  Navbar = Logos::NavbarLogo
  Stacked = Logos::StackedLogo
  DEEP_VIOLET = "#635BB2"

  def navbar(brand) = (@navbar ||= {})[brand] ||= Navbar.new(brand)
  def stacked(brand) = (@stacked ||= {})[brand] ||= Stacked.new(brand)
  def doc(svg) = Nokogiri::XML(svg) { |config| config.strict }
  def refusal(&) = assert_raises(Navbar::Error, &).message
  def fills(svg) = doc(svg).css("path").map { |path| path["fill"] }

  # A word's letters (word 0 the first, 1 the ending, 2 the tagline) as the layout places them.
  def word(box, index) = box.letters.select { |letter| letter[:word] == index }

  def test_no_edits_draws_exactly_what_it_drew
    Navbar.brands.each do |brand|
      Navbar::RULES.keys.product(Navbar::TEXTS, Navbar::TONES, [false, true]) do |rule, text, tone, guides|
        assert_equal navbar(brand).svg(rule:, text:, tone:, guides:), navbar(brand).svg(rule:, text:, tone:, guides:, edits: {})
      end
      stacked(brand).forms.product(Navbar::TEXTS, Navbar::TONES) do |form, text, tone|
        assert_equal stacked(brand).svg(form:, text:, tone:), stacked(brand).svg(form:, text:, tone:, edits: nil)
      end
    end
  end

  def test_a_word_colour_reaches_that_word_in_every_text_version_and_nothing_else
    Navbar::TEXTS.each do |text|
      plain = navbar("studio").svg(rule: 4, text:)
      edited = navbar("studio").svg(rule: 4, text:, edits: { first: { colour: DEEP_VIOLET } })
      box = navbar("studio").layout(rule: 4, text:)
      first = word(box, 0).count { |letter| !letter[:d].empty? }
      edited_fills = fills(edited)
      plain_fills = fills(plain)
      assert_equal [DEEP_VIOLET] * first, edited_fills[1, first], text   # the icon is one path, then the first word
      assert_equal plain_fills.drop(1 + first), edited_fills.drop(1 + first), "#{text}: the ending keeps its colour"
      assert_equal plain.gsub(/fill="#\h+"/, ""), edited.gsub(/fill="#\h+"/, ""), "#{text}: only fills change"
    end
  end

  def test_an_icon_colour_recolours_its_primary_layer_only
    edited = fills(navbar("industries").svg(edits: { icon: { colour: "#C8661F" } })).first(3)
    assert_equal ["#C8661F", "#8C939C", "#262A30"], edited, "the edge keeps its styled steel, the name its own ink"
    assert_equal "outline", navbar("turf").icon_role(:light), "Turf's head has no primary layer: its outline is recoloured"
    turf = fills(navbar("turf").svg(edits: { icon: { colour: "#2E7D32" } })).first(3)
    assert_equal ["#2E7D32", "#5C972A", "#F0EBCF"], turf
    assert_equal "primary", navbar("welding").icon_role(:dark), "the single-colour helmet on dark"
  end

  def test_a_heavier_word_is_wider_and_the_rules_hold
    plain = navbar("studio").layout(rule: 4, text: :homogeneous)
    lighter = navbar("studio").layout(rule: 4, text: :homogeneous, edits: { first: { weight: 300 } })
    assert_equal [plain.cap, plain.gap, plain.icon_width, plain.name_left, plain.baseline],
                 [lighter.cap, lighter.gap, lighter.icon_width, lighter.name_left, lighter.baseline], "the geometry stands"
    assert_operator lighter.word_left, :<, plain.word_left, "an 800 first word set at 300 is narrower"
    assert_in_delta plain.width - plain.word_left, lighter.width - lighter.word_left, 1e-6, "the ending is untouched"

    heavier = navbar("industries").layout(rule: 3, text: :second, edits: { ending: { weight: 800 } })
    styled = navbar("industries").layout(rule: 3, text: :second)
    assert_operator heavier.width, :>, styled.width
  end

  def test_a_weight_edit_holds_in_every_text_version
    edits = { first: { weight: 600 }, ending: { weight: 400 } }
    Navbar::TEXTS.each do |text|
      box = navbar("studio").layout(rule: 4, text:, edits:)
      reference = navbar("studio").layout(rule: 4, text: :homogeneous, edits:)
      assert_equal reference.letters.map { |l| l[:d] }, box.letters.map { |l| l[:d] }, text
    end
  end

  def test_the_stacked_two_line_form_takes_word_edits_and_keeps_the_321_method
    box = stacked("studio").layout(text: :first, edits: { first: { weight: 500 }, ending: { colour: "#8E82FE", weight: 700 } })
    assert_in_delta Stacked::SPAN * box.width, box.icon_height, 1e-6
    assert_equal [0, 2, 3, 2, 1], [0] + box.edges.each_cons(2).drop(1).map { |a, b| ((b - a) / Stacked::U).round }
  end

  def test_the_tagline_takes_a_colour_and_a_weight_and_stays_as_wide
    plain = stacked("studio").layout(form: :tagline)
    heavy = stacked("studio").layout(form: :tagline, edits: { tagline: { weight: 800 } })
    ink = ->(box) { word(box, 2).then { |run| [run.first[:x], run.last[:x]] } }
    assert_in_delta plain.edges.last, heavy.edges.last, 1e-6
    refute_equal word(plain, 2).map { |l| l[:d] }, word(heavy, 2).map { |l| l[:d] }
    assert_in_delta ink.(plain).first, ink.(heavy).first, 40, "still centred under the name"
    svg = stacked("studio").svg(form: :tagline, edits: { tagline: { colour: DEEP_VIOLET } })
    assert_equal [DEEP_VIOLET] * "BUILDSMARTER".size, fills(svg).last("BUILDSMARTER".size)
  end

  def test_a_hidden_tagline_keeps_every_band_and_is_not_drawn
    %w[studio industries welding].each do |brand|
      shown = stacked(brand).layout(form: :tagline)
      hidden = stacked(brand).layout(form: :tagline, edits: { tagline: { visible: false } })
      assert_equal shown.edges, hidden.edges, brand
      assert_equal [shown.width, shown.height, shown.icon_height, shown.icon_left], [hidden.width, hidden.height, hidden.icon_height, hidden.icon_left]
      assert_empty word(hidden, 2), brand
      assert_equal shown.letters.reject { |l| l[:word] == 2 }, hidden.letters
      view = doc(stacked(brand).svg(form: :tagline, edits: { tagline: { visible: false } })).root["viewBox"]
      assert_equal doc(stacked(brand).svg(form: :tagline)).root["viewBox"], view, "#{brand}: the same box, the tagline's band left empty"
    end
  end

  def test_tagline_edits_leave_the_other_forms_alone
    assert_equal stacked("studio").svg(form: :two_line), stacked("studio").svg(form: :two_line, edits: { tagline: { visible: false, colour: DEEP_VIOLET } })
    assert_equal navbar("studio").svg, navbar("studio").svg(edits: { tagline: { weight: 300 } })
  end

  def test_edits_are_checked_and_normalised
    assert_equal({ first: { colour: DEEP_VIOLET } }, navbar("studio").checked_edits({ first: { colour: "#635bb2" } }))
    assert_equal({}, navbar("studio").checked_edits({ tagline: { visible: true }, icon: {} }), "a change of nothing is no edit")
    assert_equal({ tagline: { visible: false } }, navbar("studio").checked_edits({ tagline: { visible: false } }))
    assert_predicate navbar("studio").checked_edits({ first: { weight: 300 } }), :frozen?
  end

  def test_refusals_name_what_is_wrong
    studio = navbar("studio")
    assert_match(/first's colour must be one of the brand's palette \(#1A1535, #8E82FE, #635BB2, #EEECFF, #FFFFFF\), got "#000000"/,
                 refusal { studio.svg(edits: { first: { colour: "#000000" } }) })
    assert_match(/must be one of the brand's palette/, refusal { studio.svg(edits: { icon: { colour: "red" } }) })
    assert_match(/no part :name to edit/, refusal { studio.svg(edits: { name: { colour: DEEP_VIOLET } }) })
    assert_match(/the icon takes colour, got/, refusal { studio.svg(edits: { icon: { weight: 300 } }) })
    assert_match(/weight must be one of 300, 400, 500, 600, 700, 800, got 900/, refusal { studio.svg(edits: { ending: { weight: 900 } }) })
    assert_match(/weight must be one of .*got "700"/, refusal { studio.svg(edits: { ending: { weight: "700" } }) })
    assert_match(/visibility must be true or false/, refusal { stacked("studio").svg(form: :tagline, edits: { tagline: { visible: "0" } }) })
    assert_match(/traced lettering, which has one weight, so the first's weight cannot change/,
                 refusal { navbar("welding").svg(edits: { first: { weight: 700 } }) })
    assert_match(/brand turf: it has no tagline to edit/, refusal { navbar("turf").svg(edits: { tagline: { visible: false } }) })
    assert_match(/a watermark is one colour, so edits do not apply/, refusal { studio.svg(tone: :watermark, edits: { first: { weight: 300 } }) })
    assert_match(/edits must be a map of parts/, refusal { studio.svg(edits: "first=red") })
  end

  def test_traced_lettering_still_takes_colours_and_its_tagline_a_weight
    svg = navbar("welding").svg(edits: { first: { colour: "#D7602E" }, ending: { colour: "#F08A5A" } })
    assert_includes fills(svg), "#F08A5A"
    assert_nil stacked("welding").refusal({ tagline: { weight: 700 } }, form: :tagline)
  end

  def test_refusal_answers_whether_every_text_version_draws
    assert_nil stacked("studio").refusal({ first: { weight: 300 }, ending: { weight: 800 } }, form: :two_line)
    assert_nil navbar("industries").refusal({ ending: { weight: 800 } }, rule: 6)
    assert_match(/palette/, stacked("studio").refusal({ first: { colour: "#000000" } }, form: :two_line))
  end
end
