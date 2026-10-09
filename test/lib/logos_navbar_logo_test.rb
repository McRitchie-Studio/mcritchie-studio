# frozen_string_literal: true

# [unit] Logos::NavbarLogo (task navbar-logo-generator): the rule of 3 and the
# rule of 4 geometry, homogeneous and highlight text, the light and dark fills,
# the guide drawing, the vector-only output, and the refusals. Task
# add-turf-and-welding-logos adds a brand's own traced lettering, tracking, an
# icon per tone, and the checks on every path the library writes into markup.

require "digest"
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
  # Measured from the prototype too (homogeneous text), for the two brands added after it was approved.
  ADDED_RATIOS = { ["turf", 3] => 4.24, ["turf", 4] => 5.87, ["welding", 3] => 5.98, ["welding", 4] => 8.52 }.freeze
  # SHA-256 over every Studio and Industries example ("<key>\n<svg>" each, in `examples` order), taken on
  # `accepted` before the two brands were added: neither brand's logos may change by a byte.
  ORIGINAL_BRANDS_DIGEST = "b3dd0ef4b8a4a56f2ad55ebfa4b12f60ed4542cf1e18fdcb4723637e5a124dc0"
  # The same digest over every Turf Monster and Commercial Welding example, taken on `accepted` before the
  # watermark tone was added (task logo-gallery-context-dropdown): a third tone may not move light or dark.
  ADDED_BRANDS_DIGEST = "087d05d81ed367d276b82e29637395efed28bec65c7b3d9692b193d8e7878736"
  HOSTILE = %(M0,0"/><script>alert(1)</script>)
  COLOUR_STYLE = { "duo" => { "name" => "Turf Monster", "icon" => "studio", "highlight" => "colour", "heavy" => 800,
                              "tones" => { "light" => { "text" => "#111111", "accent" => "#4BAF50", "icon" => { "primary" => "#111111" } },
                                           "dark" => { "text" => "#FFFFFF", "accent" => "#4BAF50", "icon" => { "primary" => "#FFFFFF" } } } } }.freeze

  def industries = @industries ||= Logo.new("industries")
  def glyph(char, weight) = Logo.glyphs.fetch(weight.to_s).fetch("glyphs").fetch(char)
  def doc(svg) = Nokogiri::XML(svg) { |config| config.strict }
  def letters(svg) = doc(svg).css("path[transform]")
  def refusal(&) = assert_raises(Logo::Error, &).message
  def studio_style(**changes) = { "x" => Logo.styles.fetch("studio").merge(changes.transform_keys(&:to_s)) }
  def welding_style(**changes) = { "x" => Logo.styles.fetch("welding").merge(changes.transform_keys(&:to_s)) }
  def deep_copy(data) = JSON.parse(JSON.generate(data))

  # The shipped icon data with one icon changed in place by the block.
  def icons_with(key = "studio")
    deep_copy(Logo.icons).tap { |icons| yield icons.fetch(key) }
  end

  # Swaps the shipped glyph data for the block (plain minitest here: no minitest/mock under minitest 6).
  def with_glyphs(glyphs)
    shipped = Logo.method(:glyphs)
    Logo.define_singleton_method(:glyphs) { glyphs }
    yield
  ensure
    Logo.define_singleton_method(:glyphs, shipped)
  end

  def letterings_with
    deep_copy(Logo.letterings).tap { |letterings| yield letterings.fetch("welding") }
  end

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
      assert_operator width, :>, 1000, example[:key]
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
    # The guard is anchored at both ends: a hex that only STARTS a longer value, or ends in a newline, is refused.
    [%(#000"/><script>), "#000000\n", "x#000000"].each do |fill|
      unanchored = style.(tones: { "light" => { "text" => "#000000", "icon" => { "primary" => fill } } })
      assert_match(/is not a #hex colour/, refusal { Logo.new("x", styles: unanchored).svg }, fill.inspect)
      text_fill = style.(tones: { "light" => { "text" => fill, "icon" => { "primary" => "#000000" } } })
      assert_match(/is not a #hex colour/, refusal { Logo.new("x", styles: text_fill).svg }, fill.inspect)
    end
    no_role = style.(tones: { "light" => { "text" => "#000000", "icon" => {} } })
    assert_match(/no fill for icon layer "primary"/, refusal { Logo.new("x", styles: no_role).svg })
  end

  def test_studio_and_industries_logos_are_unchanged_to_the_byte
    all = %w[studio industries].flat_map { |brand| Logo.new(brand).examples }.map { |e| "#{e[:key]}\n#{e[:svg]}" }.join
    assert_equal ORIGINAL_BRANDS_DIGEST, Digest::SHA256.hexdigest(all)
  end

  def test_turf_and_welding_light_and_dark_logos_are_unchanged_to_the_byte
    all = %w[turf welding].flat_map { |brand| Logo.new(brand).examples }.map { |e| "#{e[:key]}\n#{e[:svg]}" }.join
    assert_equal ADDED_BRANDS_DIGEST, Digest::SHA256.hexdigest(all)
  end

  def test_the_added_brands_match_the_prototypes_proportions
    ADDED_RATIOS.each do |(brand, rule), ratio|
      logo = Logo.new(brand)
      assert_in_delta ratio, logo.layout(rule:).width / H, 0.03, "#{brand} rule #{rule}"
      _, _, width, height = doc(logo.svg(rule:)).root["viewBox"].split.map(&:to_f)
      assert_in_delta ratio, width / height, 0.03, "#{brand} rule #{rule} viewBox"
    end
  end

  def test_a_lettering_source_sets_the_name_from_the_brands_own_letters
    traced = Logo.letterings.fetch("welding")
    words = traced.fetch("words").values_at("COMMERCIAL", "WELDING")
    logo = Logo.new("welding")
    box = logo.layout(rule: 3)
    first, second = box.letters.partition { |l| l[:word].zero? }

    assert_equal words.map { |word| word.map { |g| g["d"] } }, [first, second].map { |word| word.map { |l| l[:d] } }
    c = words[0][0]
    assert_in_delta (c["r"] - c["l"]) * box.cap / 2, box.gap, 1e-9
    assert_in_delta c["adv"] * box.cap, first[1][:x] - first[0][:x], 1e-9, "no tracking: letters advance by adv x cap"
    right1 = first.last[:x] + words[0].last["r"] * box.cap
    assert_in_delta 0.3507 * box.cap, second.first[:x] + words[1][0]["l"] * box.cap - right1, 1e-9, "the word space is the lettering's own"
    assert_in_delta second.last[:x] + words[1].last["r"] * box.cap, box.width, 1e-9

    # Traced letters carry their counters as sub-paths, so they fill evenodd; the leading word takes the accent.
    { homogeneous: ["#2D5E8E"] * 17, first: ["#D7602E"] * 10 + ["#2D5E8E"] * 7, second: ["#2D5E8E"] * 10 + ["#D7602E"] * 7 }.each do |text, fills|
      paths = letters(logo.svg(text:))
      assert_equal fills, paths.map { |p| p["fill"] }, text
      assert_equal ["evenodd"], paths.map { |p| p["fill-rule"] }.uniq, text
      assert_equal box.width, logo.layout(text:).width, "one weight: every text has the same box"
    end
    assert_equal ["nonzero"], letters(Logo.new("turf").svg).map { |p| p["fill-rule"] }.uniq, "font glyphs stay nonzero"
  end

  def test_a_lettering_source_refuses_what_it_cannot_draw
    assert_match(/one weight, so highlight must be colour, not weight/, refusal { Logo.new("x", styles: welding_style(highlight: "weight")) })
    assert_match(/no word "FORGE" in the welding lettering \(it has COMMERCIAL, WELDING\)/, refusal { Logo.new("x", styles: welding_style(name: "COMMERCIAL FORGE")) })
    assert_match(/no word "Welding"/, refusal { Logo.new("x", styles: welding_style(name: "COMMERCIAL Welding")) }, "a word is matched as written")
    assert_match(/no lettering "anvil" in the lettering data/, refusal { Logo.new("x", styles: welding_style(lettering: "anvil")) })
    assert_match(/tracking is in em, which a lettering source does not have/, refusal { Logo.new("x", styles: welding_style(tracking: -0.02)) })
  end

  def test_tracking_is_added_to_every_advance_but_not_to_the_ink_edge
    logo = Logo.new("turf")
    cap_height_em = Logo.glyphs.fetch("800").fetch("cap_height_em")
    step = -0.025 / cap_height_em
    box = logo.layout(rule: 3)
    first, second = box.letters.partition { |l| l[:word].zero? }
    assert_equal [4, 7], [first.size, second.size]

    "Turf".chars.each_cons(2).with_index do |(char, _), i|
      assert_in_delta (glyph(char, 800)["adv"] + step) * box.cap, first[i + 1][:x] - first[i][:x], 1e-9, "after #{char}"
    end
    right1 = first.last[:x] + glyph("f", 800)["r"] * box.cap
    left2 = second.first[:x] + glyph("M", 800)["l"] * box.cap
    assert_in_delta glyph(" ", 300)["adv"] * box.cap, left2 - right1, 1e-9, "the word space starts at the ink, with no trailing tracking step"
    assert_in_delta second.last[:x] + glyph("r", 800)["r"] * box.cap, box.width, 1e-9, "the box ends at the last letter's ink"

    loose = Logo.new("x", styles: { "x" => Logo.styles.fetch("turf").except("tracking") })
    assert_in_delta 9 * -step * box.cap, loose.layout(rule: 3).width - box.width, 1e-9, "eleven letters, two words: nine steps inside the words"
    assert_match(/tracking must be a number of em, got "tight"/, refusal { Logo.new("x", styles: studio_style(tracking: "tight")) })
  end

  def test_a_tone_may_name_its_own_icon
    mono = Logo.icons.fetch("welding_mono").fetch("layers")
    duo = Logo.icons.fetch("welding").fetch("layers")
    icon_paths = ->(tone) { doc(Logo.new("welding").svg(tone:)).css("path:not([transform])") }
    assert_equal [[duo[0]["d"], "#2D5E8E"], [duo[1]["d"], "#D7602E"]], icon_paths.(:light).map { |p| [p["d"], p["fill"]] }
    assert_equal [[mono[0]["d"], "#FFFFFF"]], icon_paths.(:dark).map { |p| [p["d"], p["fill"]] }
    refute_equal duo[0]["d"], mono[0]["d"]

    # The tone's icon sets that tone's geometry; a tone that names none keeps the brand's.
    tones = Logo.styles.fetch("studio").fetch("tones")
    dark = tones.fetch("dark").merge("icon_key" => "industries", "icon" => { "primary" => "#FFFFFF", "edge" => "#FFFFFF" })
    logo = Logo.new("x", styles: studio_style(tones: tones.merge("dark" => dark)))
    assert_in_delta 666.0 * H / 541, logo.layout(tone: :light).icon_width, 1e-9
    assert_in_delta 215.0 * H / 217, logo.layout(tone: :dark).icon_width, 1e-9
    assert_equal "translate(-190,-166)", doc(logo.svg(tone: :dark)).root.at_css("g g")["transform"]
    assert_equal Logo.new("studio").svg(tone: :light), logo.svg(tone: :light)

    missing = tones.merge("dark" => tones.fetch("dark").merge("icon_key" => "anvil"))
    assert_match(/no icon "anvil" in the icon data/, refusal { Logo.new("x", styles: studio_style(tones: missing)) })
  end

  def test_every_shipped_path_fill_rule_and_transform_passes_the_checks
    layers = Logo.icons.values.flat_map { |icon| icon.fetch("layers") }
    glyphs = Logo.glyphs.values.flat_map { |set| set.fetch("glyphs").values }
    traced = Logo.letterings.values.flat_map { |lettering| lettering.fetch("words").values.flatten }
    assert_equal [5, 9, 6 * 95, 17], [Logo.icons.size, layers.size, glyphs.size, traced.size]

    (layers + glyphs + traced).each { |item| assert_match Logo::PATH, item.fetch("d") }
    assert_empty layers.map { |l| l["fill_rule"] }.uniq - Logo::FILL_RULES
    assert_equal ["evenodd"], Logo.letterings.values.map { |l| l["fill_rule"] }
    assert_equal ["translate(-190,-166)"], Logo.icons.values.filter_map { |icon| icon["transform"] }
    Logo.brands.each { |brand| assert_kind_of Logo, Logo.new(brand) }
  end

  def test_an_icon_path_fill_rule_or_transform_that_could_break_out_of_the_markup_is_refused
    refuse = ->(pattern, value, &change) do
      message = refusal { Logo.new("studio", icons: icons_with("studio", &change)) }
      assert_match pattern, message, value.inspect
    end
    # Anchored at both ends: path data that only STARTS clean, or ends in a newline, is refused.
    [HOSTILE, "M0,0 L1,1 Z\n", "\nM0,0", "M0,0 url(#x)", "M0,0<", "M0 0 & L1 1", nil, 7, ["M0,0"]].each do |d|
      refuse.(/icon studio layer "primary" has a path that is not SVG path data/, d) { |icon| icon["layers"][0]["d"] = d }
    end
    ["evenodd\n", %(evenodd"/><script>), "EVENODD", "", nil, "inherit"].each do |rule|
      refuse.(/icon studio layer "primary" has fill rule .*expected nonzero or evenodd/m, rule) { |icon| icon["layers"][0]["fill_rule"] = rule }
    end
    [%(translate(1,2)"><script>), "translate(1,2)\n", "skewX(3)", "translate(a)", "translate()", "url(#x)", "", " scale(2)", "scale(2) ",
     "scale(2);rotate(3)", "translate(1,2", 5, ["scale(2)"]].each do |transform|
      refuse.(/icon studio has a transform that is not a list of translate, scale, rotate or matrix calls/, transform) { |icon| icon["transform"] = transform }
    end

    # The check is the brand's own icons, on every tone: a hostile icon the brand never draws is not its business.
    assert_kind_of Logo, Logo.new("studio", icons: icons_with("turf") { |icon| icon["layers"][0]["d"] = HOSTILE })
    assert_match(/icon welding_mono layer "primary" has a path/, refusal { Logo.new("welding", icons: icons_with("welding_mono") { |icon| icon["layers"][0]["d"] = HOSTILE }) })
  end

  def test_a_plain_list_of_transform_calls_is_drawn
    ["translate(-190,-166)", "translate(1 2) scale(0.5)", "matrix(1,0,0,1,-3.5,4e1) rotate(45)", "scale(-.5,+2)"].each do |transform|
      svg = Logo.new("studio", icons: icons_with { |icon| icon["transform"] = transform }).svg
      assert_equal transform, doc(svg).root.at_css("g g")["transform"]
    end
  end

  def test_lettering_and_glyph_paths_are_checked_like_icon_paths
    [HOSTILE, "M0,0 Z\n"].each do |d|
      hostile = letterings_with { |lettering| lettering["words"]["WELDING"][3]["d"] = d }
      assert_match(/a letter of "WELDING" has a path that is not SVG path data/, refusal { Logo.new("welding", letterings: hostile) }, d.inspect)
    end
    ["evenodd\n", %(evenodd" onload="x), nil].each do |rule|
      hostile = letterings_with { |lettering| lettering["fill_rule"] = rule }
      assert_match(/a letter of "COMMERCIAL" has fill rule .*expected nonzero or evenodd/m, refusal { Logo.new("welding", letterings: hostile) }, rule.inspect)
    end

    glyphs = deep_copy(Logo.glyphs)
    glyphs["800"]["glyphs"]["S"]["d"] = HOSTILE
    with_glyphs(glyphs) do
      assert_match(/a letter of "STUDIO" has a path that is not SVG path data/, refusal { Logo.new("studio") })
      assert_kind_of Logo, Logo.new("industries"), "industries sets no letter at weight 800"
    end
  end
end
