# frozen_string_literal: true

# [unit] Logos::NavbarLogo (task navbar-logo-generator): the rule of 3 and the
# rule of 4 geometry, homogeneous and highlight text, the light and dark fills,
# the guide drawing, the vector-only output, and the refusals.

require "minitest/autorun"
require "nokogiri"
require_relative "../../lib/logos/navbar_logo"

class LogosNavbarLogoTest < Minitest::Test
  Logo = Logos::NavbarLogo
  H = Logo::H
  # Width / height of the logo box, measured from the Python prototype Alex approved.
  PROTOTYPE_RATIOS = {
    ["industries", 3, :first] => 6.85, ["industries", 3, :second] => 6.83, ["industries", 3, :homogeneous] => 6.97,
    ["industries", 4, :second] => 9.75,
    ["studio", 3, :first] => 6.08, ["studio", 3, :second] => 6.00, ["studio", 3, :homogeneous] => 6.18
  }.freeze
  COLOUR_STYLE = { "duo" => { "name" => "Turf Monster", "icon" => "studio", "highlight" => "colour", "heavy" => 800,
                              "tones" => { "light" => { "text" => "#111111", "accent" => "#4BAF50", "icon" => { "primary" => "#111111" } },
                                           "dark" => { "text" => "#FFFFFF", "accent" => "#4BAF50", "icon" => { "primary" => "#FFFFFF" } } } } }.freeze

  def industries = @industries ||= Logo.new("industries")
  def glyph(char, weight) = Logo.glyphs.fetch(weight.to_s).fetch("glyphs").fetch(char)
  def doc(svg) = Nokogiri::XML(svg) { |config| config.strict }
  def letters(svg) = doc(svg).css("path[transform]")
  def refusal(&) = assert_raises(Logo::Error, &).message

  # The y extent of a glyph's outline in cap heights (every command in the data is absolute).
  def ink_y(d)
    ys = d.scan(/([MLQHV])([^MLQHVZ]*)/).flat_map do |command, args|
      numbers = args.split.map(&:to_f)
      { "H" => [], "V" => numbers }.fetch(command) { numbers.each_slice(2).map(&:last) }
    end
    ys.minmax
  end

  def test_the_glyph_data_sets_capitals_from_the_baseline_to_one_cap_height
    %w[M I H E].each { |char| assert_equal [-1.0, 0.0], ink_y(glyph(char, 700)["d"]), char }
  end

  def test_rule_of_3_puts_the_capitals_in_the_middle_row
    box = industries.layout(rule: 3, text: :first)
    assert_in_delta H / 3, box.cap
    assert_in_delta 100, box.baseline - box.cap, 1e-9, "the capitals' top is the first row edge"
    assert_in_delta 200, box.baseline, 1e-9, "the baseline is the second row edge"

    first = letters(industries.svg(rule: 3, text: :first)).first
    assert_match(/\Atranslate\([\d.]+,200\.00\) scale\(100\.0000\)\z/, first["transform"])
  end

  def test_rule_of_4_fills_the_middle_two_rows
    box = industries.layout(rule: 4, text: :second)
    assert_in_delta H / 2, box.cap
    assert_in_delta 75, box.baseline - box.cap, 1e-9, "the capitals' top is the first of four row edges"
    assert_in_delta 225, box.baseline, 1e-9, "the baseline is the third row edge"

    first = letters(industries.svg(rule: 4, text: :second)).first
    assert_match(/\Atranslate\([\d.]+,225\.00\) scale\(150\.0000\)\z/, first["transform"])
  end

  def test_the_gap_is_half_the_first_letter_and_the_word_space_is_the_fonts_own
    box = industries.layout(rule: 3, text: :first)
    m = glyph("M", 700)
    assert_in_delta 215.0 * H / 217, box.icon_width, 1e-9
    assert_in_delta (m["r"] - m["l"]) * box.cap / 2, box.gap, 1e-9
    assert_in_delta box.icon_width + box.gap, box.letters.first[:x] + m["l"] * box.cap, 1e-9, "the first letter's ink starts after the gap"

    word1, word2 = box.letters.partition { |l| l[:word].zero? }
    assert_equal [9, 10], [word1.size, word2.size]
    right1 = word1.last[:x] + glyph("E", 700)["r"] * box.cap
    left2 = word2.first[:x] + glyph("I", 300)["l"] * box.cap
    assert_in_delta glyph(" ", 300)["adv"] * box.cap, left2 - right1, 1e-9
    assert_in_delta glyph("M", 700)["adv"] * box.cap, word1[1][:x] - word1[0][:x], 1e-9, "letters advance by adv x cap, no kerning"
    assert_in_delta word2.last[:x] + glyph("S", 300)["r"] * box.cap, box.width, 1e-9, "the box ends at the last letter's ink"
  end

  def test_the_box_matches_the_prototypes_proportions
    PROTOTYPE_RATIOS.each do |(brand, rule, text), ratio|
      logo = Logo.new(brand)
      assert_in_delta ratio, logo.layout(rule:, text:).width / H, 0.03, "#{brand} rule #{rule} #{text}"
      _, _, width, height = doc(logo.svg(rule:, text:)).root["viewBox"].split.map(&:to_f)
      assert_in_delta ratio, width / height, 0.03, "#{brand} rule #{rule} #{text} viewBox"
    end
  end

  def test_highlight_by_weight_leads_with_either_word_and_homogeneous_is_one_weight_one_colour
    heavy = ->(word) { word.chars.map { |c| glyph(c, 700)["d"] } }
    light = ->(word) { word.chars.map { |c| glyph(c, 300)["d"] } }
    expected = {
      first: [heavy.("McRITCHIE") + light.("INDUSTRIES"), ["#262A30"] * 9 + ["#41464D"] * 10],
      second: [light.("McRITCHIE") + heavy.("INDUSTRIES"), ["#41464D"] * 9 + ["#262A30"] * 10],
      homogeneous: [heavy.("McRITCHIE") + heavy.("INDUSTRIES"), ["#262A30"] * 19]
    }
    expected.each do |text, (outlines, fills)|
      paths = letters(industries.svg(text:, tone: :light))
      assert_equal outlines, paths.map { |p| p["d"] }, "#{text} outlines"
      assert_equal fills, paths.map { |p| p["fill"] }, "#{text} fills"
      assert_equal ["nonzero"], paths.map { |p| p["fill-rule"] }.uniq
    end
  end

  def test_highlight_by_colour_keeps_both_words_heavy_and_colours_the_leading_word
    logo = Logo.new("duo", styles: COLOUR_STYLE)
    { first: ["#4BAF50"] * 4 + ["#111111"] * 7, second: ["#111111"] * 4 + ["#4BAF50"] * 7, homogeneous: ["#111111"] * 11 }.each do |text, fills|
      paths = letters(logo.svg(text:))
      assert_equal fills, paths.map { |p| p["fill"] }, text
      assert_equal "Turf Monster".delete(" ").chars.map { |c| glyph(c, 800)["d"] }, paths.map { |p| p["d"] }, text
    end
  end

  def test_light_and_dark_share_the_geometry_and_differ_in_fills
    light, dark = %i[light dark].map { |tone| industries.svg(rule: 4, text: :second, tone:) }
    strip = ->(svg) { svg.gsub(/ fill="#\h+"/, "") }
    assert_equal strip.(light), strip.(dark)
    assert_equal %w[#262A30 #8C939C #41464D], doc(light).css("path").map { |p| p["fill"] }.uniq
    assert_equal %w[#D3D6DA #FFFFFF #F4F5F7], doc(dark).css("path").map { |p| p["fill"] }.uniq
  end

  def test_the_icon_is_scaled_to_the_design_height_inside_its_own_transform
    root = doc(industries.svg).root
    scale = root.element_children.first
    assert_equal "scale(#{format('%.5f', H / 217)})", scale["transform"]
    assert_equal "translate(-190,-166)", scale.element_children.first["transform"]
    assert_equal %w[evenodd nonzero], scale.css("path").map { |p| p["fill-rule"] }
    assert_nil doc(Logo.new("studio").svg).root.at_css("g g"), "studio's icon has no inner transform"
  end

  def test_every_example_without_guides_is_paths_only_in_the_logos_own_box
    examples = Logo.brands.flat_map { |brand| Logo.new(brand).examples }
    assert_equal 24 * Logo.brands.size, examples.size
    assert_equal examples.size, examples.map { |e| e[:key] }.uniq.size
    plain = examples.reject { |e| e[:guides] }
    assert_equal 12 * Logo.brands.size, plain.size

    plain.each do |example|
      xml = doc(example[:svg])
      assert_empty xml.errors, example[:key]
      assert_equal %w[g path svg], xml.xpath("//*").map(&:name).uniq.sort, example[:key]
      refute_match(/href|url\(|@font-face|<style|data:/, example[:svg], example[:key])
      x, y, width, height = xml.root["viewBox"].split.map(&:to_f)
      assert_equal [0.0, 0.0, 300.0], [x, y, height], example[:key]
      assert_operator width, :>, 1500, example[:key]
    end
  end

  def test_guides_draw_the_row_edges_the_two_verticals_and_the_row_numbers
    { 3 => :first, 4 => :second }.each do |rule, text|
      box = industries.layout(rule:, text:)
      xml = doc(industries.svg(rule:, text:, guides: true))
      xml.remove_namespaces!
      horizontal, vertical = xml.css("line").partition { |l| l["y1"] == l["y2"] }
      assert_equal (0..rule).map { |i| format("%.2f", i * H / rule) }, horizontal.map { |l| l["y1"] }
      assert_equal [box.icon_width, box.name_left].map { |x| format("%.2f", x) }, vertical.map { |l| l["x1"] }
      assert_equal (1..rule).map(&:to_s), xml.css("text").map(&:text)
      assert_equal industries.svg(rule:, text:).scan(/<path /).size, xml.css("path").size, "guides add no paths"
      assert_equal format("-40 -40 %.2f 380.00", box.width + 120), xml.root["viewBox"]
    end
  end

  def test_refusals_name_what_is_wrong
    style = ->(**changes) { { "x" => Logo.styles.fetch("studio").merge(changes.transform_keys(&:to_s)) } }
    assert_match(/unknown brand "acme": expected one of studio, industries/, refusal { Logo.new("acme") })
    assert_match(/unknown rule 5: expected 3 or 4/, refusal { industries.svg(rule: 5) })
    assert_match(/unknown text :third/, refusal { industries.svg(text: :third) })
    assert_match(/unknown tone :sepia/, refusal { industries.svg(tone: :sepia) })
    assert_match(/no glyph for "Ü" at weight 800/, refusal { Logo.new("x", styles: style.(name: "McRITCHIE STÜDIO")) })
    assert_match(/exactly two words, got 3/, refusal { Logo.new("x", styles: style.(name: "McRITCHIE STUDIO LABS")) })
    assert_match(/exactly two words, got 1/, refusal { Logo.new("x", styles: style.(name: "STUDIO")) })
    assert_match(/exactly two words, got 0/, refusal { Logo.new("x", styles: style.(name: nil)) })
    assert_match(/no icon "anvil"/, refusal { Logo.new("x", styles: style.(icon: "anvil")) })
    assert_match(/highlight must be one of weight, colour/, refusal { Logo.new("x", styles: style.(highlight: "size")) })
    assert_match(/no Montserrat weight 950/, refusal { Logo.new("x", styles: style.(heavy: 950)) })
    bad_fill = style.(tones: { "light" => { "text" => %(red"/><image href="x), "icon" => { "primary" => "#000000" } } })
    assert_match(/is not a #hex colour/, refusal { Logo.new("x", styles: bad_fill).svg })
    no_role = style.(tones: { "light" => { "text" => "#000000", "icon" => {} } })
    assert_match(/no fill for icon layer "primary"/, refusal { Logo.new("x", styles: no_role).svg })
  end
end
