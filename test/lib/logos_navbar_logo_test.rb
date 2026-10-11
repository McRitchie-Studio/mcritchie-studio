# frozen_string_literal: true

# [unit] Logos::NavbarLogo (task navbar-logo-generator): the rule of 3 and the
# rule of 4 geometry, homogeneous and highlight text, the light and dark fills,
# the guide drawing, the vector-only output, and the refusals. Task
# add-turf-and-welding-logos adds a brand's own traced lettering, tracking, an
# icon per tone, and the checks on every path the library writes into markup.
# Task logo-gallery-context-dropdown adds the watermark tone: one fill, one
# translucent group, a single-colour icon where the brand needs one.

require "digest"
require "minitest/autorun"
require "nokogiri"
require_relative "../../lib/logos/navbar_logo"

class LogosNavbarLogoTest < Minitest::Test
  Logo = Logos::NavbarLogo
  H = Logo::H
  # Width / height of the logo box. First measured from the Python prototype Alex approved; re-measured when task
  # navbar-spacing-and-rotated-guides made the icon gap and the word gap each half a cap height (item 4c). Before it:
  # industries 3 6.85 / 6.83 / 6.97, industries 4 second 9.75, studio 3 6.08 / 6.00 / 6.18.
  PROTOTYPE_RATIOS = {
    ["industries", 3, :first] => 6.871, ["industries", 3, :second] => 6.873, ["industries", 3, :homogeneous] => 6.989,
    ["industries", 4, :second] => 9.815,
    ["studio", 3, :first] => 6.100, ["studio", 3, :second] => 6.046, ["studio", 3, :homogeneous] => 6.198
  }.freeze
  # The same for the two brands added after the prototype (homogeneous text). Before the equal gaps: turf 4.24 and
  # 5.87, welding 5.98 and 8.52.
  ADDED_RATIOS = { ["turf", 3] => 4.303, ["turf", 4] => 5.965, ["welding", 3] => 6.867, ["welding", 4] => 9.859 }.freeze
  # Commercial Welding v1 was 6.065 and 8.657 as COMMERCIAL WELDING, before it took LLC (task welding-llc-and-v2-helmet).
  # SHA-256 over every Studio and Industries example WITHOUT guides ("<key>\n<svg>" each, in `examples` order): neither
  # brand's logos may change by a byte. Taken on `accepted` at 4368b9183 (task stacked-tagline-and-ghost-grid), where
  # the earlier digests over examples WITH guides (b3dd0ef4…, 087d05d8…, a75b407b… since task add-turf-and-welding-logos)
  # still passed; guide drawings are construction drawings and are free to change. Re-taken DELIBERATELY by task
  # navbar-spacing-and-rotated-guides, after Alex's item 4c made the icon gap and the word gap each half a cap height
  # (was 39266841…; the turf and welding digest was 315197c0…, the watermark digest 6d1da5ed…).
  ORIGINAL_BRANDS_DIGEST = "57f95414f8cab2fddd83b5aef42cccbb70e26fe04f70983a1ec15da5c32398f4"
  # The same digest over every Turf Monster and Commercial Welding example without guides.
  # Re-taken DELIBERATELY by task welding-llc-and-v2-helmet, when Commercial Welding v1 took its whole name, COMMERCIAL WELDING LLC (Alex, item 5); was 84708d03…. Turf Monster did not move (logos_brand_pins_test.rb).
  ADDED_BRANDS_DIGEST = "3251e085eccc13a25870218d3654bb274ff459cc95da8a950feff639d9de314c"
  # Every watermark logo of all four brands, without guides ("<key>\n<svg>" each: brand, then rule and text).
  # Re-taken DELIBERATELY by task welding-llc-and-v2-helmet, when Commercial Welding v1 took its whole name, COMMERCIAL WELDING LLC (Alex, item 5); was 69c5428f….
  WATERMARK_DIGEST = "817c912e0b1ded68805948d7048f9a799baaa9e8c3c1eb403064f1af24916ef2"
  # Every rule-of-6 logo of all four brands, light, dark and watermark, without guides (task navbar-spacing-and-rotated-guides).
  # Re-taken DELIBERATELY by task welding-llc-and-v2-helmet, when Commercial Welding v1 took its whole name, COMMERCIAL WELDING LLC (Alex, item 5); was c16934f5….
  RULE_6_DIGEST = "2581fbeb23a878ca5dda233f2da62bd23c2a671bf024a486b9694218e5ad0e54"
  # The brands the combined digests below were taken over. A brand added later (welding_v2) is pinned on its own in
  # logos_brand_pins_test.rb, so it cannot move these.
  PINNED = %w[studio industries turf welding].freeze
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

  # Item 4c (task navbar-spacing-and-rotated-guides): the icon gap was half the first letter's ink and the word gap
  # the font's space (0.367 cap heights; the welding lettering's 0.351), so "hie stu" looked tight. Both are now
  # half a cap height, ink to ink, on every rule.
  # Item 4d (task navbar-spacing-and-rotated-guides): "a rule of 6 navbar where the text takes the height of 4".
  def test_rule_of_6_fills_the_middle_four_of_six_rows
    box = industries.layout(rule: 6, text: :second)
    assert_equal 6, box.count
    assert_in_delta H / 6, box.row
    assert_in_delta 4 * H / 6, box.cap, 1e-9, "the capitals are four rows"
    assert_in_delta H / 6, box.baseline - box.cap, 1e-9, "one row above the capitals"
    assert_in_delta H / 6, H - box.baseline, 1e-9, "and one below"
    first = letters(industries.svg(rule: 6, text: :second)).first
    assert_match(/\Atranslate\([\d.]+,250\.00\) scale\(200\.0000\)\z/, first["transform"])
    assert_in_delta 100, box.gap, 1e-9, "the gaps are half a cap height here too"
    four = industries.layout(rule: 4, text: :second)
    assert_in_delta (four.width - four.icon_width) * 4 / 3, box.width - box.icon_width, 1e-9, "the name, a third larger than the rule of 4's"

    xml = doc(industries.svg(rule: 6, text: :second, guides: true)).remove_namespaces!
    rows = xml.css("g.guide-lines line").select { |l| l["y1"] == l["y2"] && !l["y1"].start_with?("-") }
    assert_equal (0..6).map { |i| format("%.2f", i * 50.0) }, rows.map { |l| l["y1"] }
    assert_equal %w[1 2 3 4 5 6 ½ ½], xml.css("g.guide-lines text").map(&:text), "numbered 1-6, and the two gaps"
    assert_equal 40, industries.guide_font(6)
    assert_equal 30, industries.guide_font(4)
  end

  def test_the_icon_gap_and_the_word_gap_are_each_half_a_cap_height
    box = industries.layout(rule: 3, text: :first)
    m = glyph("M", 700)
    assert_in_delta 215.0 * H / 217, box.icon_width, 1e-9
    assert_in_delta box.cap / 2, box.gap, 1e-9
    assert_in_delta box.icon_width + box.gap, box.letters.first[:x] + m["l"] * box.cap, 1e-9, "the first letter's ink starts after the gap"

    word1, word2 = box.letters.partition { |l| l[:word].zero? }
    assert_equal [9, 10], [word1.size, word2.size]
    right1 = word1.last[:x] + glyph("E", 700)["r"] * box.cap
    left2 = word2.first[:x] + glyph("I", 300)["l"] * box.cap
    assert_in_delta box.cap / 2, left2 - right1, 1e-9, "the word gap, ink to ink"
    assert_in_delta left2, box.word_left, 1e-9
    Logo.brands.product(Logo::RULES.keys, Logo::TEXTS).each do |brand, rule, text|
      each = Logo.new(brand).layout(rule:, text:)
      assert_in_delta each.cap / 2, each.name_left - each.icon_width, 1e-9, "#{brand} #{rule} #{text}: the icon gap"
      assert_in_delta each.cap / 2, each.gap, 1e-9, "#{brand} #{rule} #{text}"
    end
    assert_in_delta glyph("M", 700)["adv"] * box.cap, word1[1][:x] - word1[0][:x], 1e-9, "letters advance by adv x cap, no kerning"
    assert_in_delta word2.last[:x] + glyph("S", 300)["r"] * box.cap, box.width, 1e-9, "the box ends at the last letter's ink"
  end

  def test_the_box_matches_the_prototypes_proportions
    PROTOTYPE_RATIOS.each do |(brand, rule, text), ratio|
      logo = Logo.new(brand)
      assert_in_delta ratio, logo.layout(rule:, text:).width / H, 0.001, "#{brand} rule #{rule} #{text}"
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
    assert_equal 36 * Logo.brands.size, examples.size
    assert_equal examples.size, examples.map { |e| e[:key] }.uniq.size
    plain = examples.reject { |e| e[:guides] }
    assert_equal 18 * Logo.brands.size, plain.size

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
      bars, horizontal = horizontal.partition { |l| l["y1"].to_f.negative? }
      assert_equal (0..rule).map { |i| format("%.2f", i * H / rule) }, horizontal.map { |l| l["y1"] }
      edges, ticks = vertical.partition { |l| l["y1"] == "-20.00" }
      assert_equal [box.icon_width, box.name_left].map { |x| format("%.2f", x) }, edges.map { |l| l["x1"] }
      assert_equal (1..rule).map(&:to_s) + %w[½ ½], xml.css("text").map(&:text)
      assert_equal industries.svg(rule:, text:).scan(/<path /).size, xml.css("path").size - xml.css("g.guide-ghosts path").size, "guides add no logo paths"
      assert_equal format("-40 -70 %.2f 410.00", box.width + 120), xml.root["viewBox"]

      # Item 4c: a bracket over each of the two equal gaps, labelled the same.
      spans = [[box.icon_width, box.name_left], [box.word_left - box.gap, box.word_left]]
      assert_equal spans.map { |a, b| [format("%.2f", a), format("%.2f", b)] }, bars.map { |l| [l["x1"], l["x2"]] }, "#{rule}: a bar over each gap"
      assert_equal spans.flatten.map { |x| format("%.2f", x) }, ticks.map { |l| l["x1"] }, "#{rule}: ticked at each gap's two ink edges"
      halves = xml.css("text[data-gap]")
      assert_equal [["0.5", "½"]] * 2, halves.map { |t| [t["data-gap"], t.text] }
      assert_equal spans.map { |a, b| format("%.2f", (a + b) / 2) }, halves.map { |t| t["x"] }, "#{rule}: each label centred on its gap"
      spans.each { |a, b| assert_in_delta box.cap / 2, b - a, 1e-9, "#{rule}: the two spans are equal, half a cap height" }
    end
  end

  def test_refusals_name_what_is_wrong
    style = ->(**changes) { { "x" => Logo.styles.fetch("studio").merge(changes.transform_keys(&:to_s)) } }
    assert_match(/unknown brand "acme": expected one of studio, industries/, refusal { Logo.new("acme") })
    assert_match(/unknown rule 5: expected one of 3, 4, 6/, refusal { industries.svg(rule: 5) })
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
    [%(#000"/><script>), "#000000\n", "\n#000000", "x#000000"].each do |fill|
      unanchored = style.(tones: { "light" => { "text" => "#000000", "icon" => { "primary" => fill } } })
      assert_match(/is not a #hex colour/, refusal { Logo.new("x", styles: unanchored).svg }, fill.inspect)
      text_fill = style.(tones: { "light" => { "text" => fill, "icon" => { "primary" => "#000000" } } })
      assert_match(/is not a #hex colour/, refusal { Logo.new("x", styles: text_fill).svg }, fill.inspect)
    end
    no_role = style.(tones: { "light" => { "text" => "#000000", "icon" => {} } })
    assert_match(/no fill for icon layer "primary"/, refusal { Logo.new("x", styles: no_role).svg })
  end

  # The pinned rules are 3 and 4 (the rule of 6 came later, with its own pin), so a new rule cannot move them.
  def unguided(brands, rules = [3, 4])
    brands.flat_map { |brand| Logo.new(brand).examples }.reject { |e| e[:guides] }.select { |e| rules.include?(e[:rule]) }.map { |e| "#{e[:key]}\n#{e[:svg]}" }
  end

  def test_studio_and_industries_logos_are_unchanged_to_the_byte
    assert_equal 24, unguided(%w[studio industries]).size
    assert_equal ORIGINAL_BRANDS_DIGEST, Digest::SHA256.hexdigest(unguided(%w[studio industries]).join)
  end

  def test_turf_and_welding_light_and_dark_logos_are_unchanged_to_the_byte
    assert_equal ADDED_BRANDS_DIGEST, Digest::SHA256.hexdigest(unguided(%w[turf welding]).join)
  end

  def test_every_rule_of_6_logo_is_unchanged_to_the_byte
    all = unguided(PINNED, [6]) + PINNED.flat_map { |brand| Logo::TEXTS.map { |text| "#{brand}-rule6-#{text}-watermark\n#{Logo.new(brand).svg(rule: 6, text:, tone: :watermark)}" } }
    assert_equal 36, all.size
    assert_equal RULE_6_DIGEST, Digest::SHA256.hexdigest(all.join)
  end

  def test_every_watermark_logo_is_unchanged_to_the_byte
    all = PINNED.flat_map do |brand|
      logo = Logo.new(brand)
      [3, 4].product(Logo::TEXTS).map do |rule, text|
        "#{brand}-rule#{rule}-#{text}-watermark\n#{logo.svg(rule:, text:, tone: :watermark)}"
      end
    end
    assert_equal 24, all.size
    assert_equal WATERMARK_DIGEST, Digest::SHA256.hexdigest(all.join)
  end

  # Task logo-tabs-icon-and-stacked: the icon alone.
  def test_the_icon_alone_is_the_navbar_logos_icon_in_its_own_box
    Logo.brands.product(Logo::TONES).each do |brand, tone|
      logo = Logo.new(brand)
      key = { %w[welding dark] => "welding_mono", %w[welding watermark] => "welding_mono", %w[turf watermark] => "turf_mono",
              %w[welding_v2 dark] => "welding_v2_mono", %w[welding_v2 watermark] => "welding_v2_mono" }.fetch([brand, tone.to_s], brand)
      icon = Logo.icons.fetch(key)
      xml = doc(logo.icon_svg(tone:))
      where = "#{brand} #{tone}"

      assert_equal "0 0 #{format('%.2f', icon['w'])} #{format('%.2f', icon['h'])}", xml.root["viewBox"], where
      assert_equal %w[g path], xml.root.xpath(".//*").map(&:name).uniq.sort, "#{where}: paths only"
      in_logo = doc(logo.svg(rule: 4, tone:)).css("path:not([transform])").map { |p| [p["d"], p["fill"], p["fill-rule"]] }
      assert_equal in_logo, xml.css("path").map { |p| [p["d"], p["fill"], p["fill-rule"]] }, "#{where}: the same layers and fills as in the logo"
      assert_equal icon.fetch("layers").map { |l| l["d"] }, xml.css("path").map { |p| p["d"] }, where
      assert_equal (tone == :watermark ? [["g", "0.6"]] : [["g", nil]]), xml.root.element_children.map { |n| [n.name, n["opacity"]] }, where
      assert_equal (tone == :watermark ? 1 : 0), logo.icon_svg(tone:).scan("opacity").size, where
      assert_includes xml.root.to_s, %(scale(1.00000)), "#{where}: drawn at the icon data's own size"
    end
    assert_equal Logo.new("studio").icon_svg, Logo.new("studio").icon_svg(tone: :light), "light unless asked"
    assert_match(/unknown tone :sepia: expected one of light, dark, watermark/, refusal { industries.icon_svg(tone: :sepia) })
  end

  def test_the_watermark_settings_are_readable_and_not_the_logos_own_copy
    assert_equal({ "fill" => "#FFFFFF", "opacity" => 0.6 }, industries.watermark)
    assert_equal({ "fill" => "#FFFFFF", "opacity" => 0.6, "icon_key" => "turf_mono" }, Logo.new("turf").watermark)
    industries.watermark["fill"] = "#000000"
    assert_equal "#FFFFFF", industries.watermark["fill"]
  end

  def test_the_added_brands_match_the_prototypes_proportions
    ADDED_RATIOS.each do |(brand, rule), ratio|
      logo = Logo.new(brand)
      assert_in_delta ratio, logo.layout(rule:).width / H, 0.001, "#{brand} rule #{rule}"
      _, _, width, height = doc(logo.svg(rule:)).root["viewBox"].split.map(&:to_f)
      assert_in_delta ratio, width / height, 0.03, "#{brand} rule #{rule} viewBox"
    end
  end

  def test_a_lettering_source_sets_the_name_from_the_brands_own_letters
    traced = Logo.letterings.fetch("welding")
    words = traced.fetch("words").values_at("COMMERCIAL", "WELDING")
    logo = Logo.new("x", styles: welding_style(name: "COMMERCIAL WELDING"))
    box = logo.layout(rule: 3)
    first, second = box.letters.partition { |l| l[:word].zero? }

    assert_equal words.map { |word| word.map { |g| g["d"] } }, [first, second].map { |word| word.map { |l| l[:d] } }
    c = words[0][0]
    assert_in_delta box.cap / 2, box.gap, 1e-9, "the icon gap is half a cap height, like every brand's"
    assert_in_delta c["adv"] * box.cap, first[1][:x] - first[0][:x], 1e-9, "no tracking: letters advance by adv x cap"
    right1 = first.last[:x] + words[0].last["r"] * box.cap
    assert_in_delta 0.5 * box.cap, second.first[:x] + words[1][0]["l"] * box.cap - right1, 1e-9, "the word gap is half a cap height, not the lettering's own space"
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
    assert_match(/no word "FORGE" in the welding lettering \(it has COMMERCIAL, WELDING, LLC\)/, refusal { Logo.new("x", styles: welding_style(name: "COMMERCIAL FORGE")) })
    assert_match(/no word "INC" in the welding lettering/, refusal { Logo.new("x", styles: welding_style(name: "COMMERCIAL WELDING INC")) })
    assert_match(/a first word and an ending of one or more words, got 1/, refusal { Logo.new("x", styles: welding_style(name: "WELDING")) })
    no_space = letterings_with { |lettering| lettering["spaces"].delete("WELDING LLC") }
    assert_match(/no space between WELDING and LLC/, refusal { Logo.new("x", styles: welding_style(name: "COMMERCIAL WELDING LLC"), letterings: no_space) })
    bad_space = letterings_with { |lettering| lettering["spaces"]["WELDING LLC"] = "0.43" }
    assert_match(/no space between WELDING and LLC/, refusal { Logo.new("x", styles: welding_style(name: "COMMERCIAL WELDING LLC"), letterings: bad_space) })
    assert_match(/no word "Welding"/, refusal { Logo.new("x", styles: welding_style(name: "COMMERCIAL Welding")) }, "a word is matched as written")
    assert_match(/no lettering "anvil" in the lettering data/, refusal { Logo.new("x", styles: welding_style(lettering: "anvil")) })
    assert_match(/tracking is in em, which a lettering source does not have/, refusal { Logo.new("x", styles: welding_style(tracking: -0.02)) })
  end

  # Task welding-llc-and-v2-helmet: the name is a first word and an ending; in a brand's own lettering the ending may
  # be several traced words, set apart by the kit's own space between them (measured from the kit's PNG).
  def test_a_traced_ending_of_several_words_keeps_the_kits_space_between_them
    lettering = Logo.letterings.fetch("welding")
    commercial, welding, llc = lettering.fetch("words").values_at("COMMERCIAL", "WELDING", "LLC")
    logo = Logo.new("x", styles: welding_style(name: "COMMERCIAL WELDING LLC"))
    assert_equal ["COMMERCIAL", "WELDING LLC"], logo.words, "two parts: the first word and the ending"
    box = logo.layout(rule: 3)
    first, ending = box.letters.partition { |l| l[:word].zero? }
    assert_equal commercial.map { |g| g["d"] }, first.map { |l| l[:d] }
    assert_equal (welding + llc).map { |g| g["d"] }, ending.map { |l| l[:d] }, "the ending is one word to the logo: one colour, one gap rule"

    right1 = first.last[:x] + commercial.last["r"] * box.cap
    assert_in_delta 0.5 * box.cap, ending.first[:x] - right1, 1e-9, "the word gap after the first word is the rule's half cap height"
    g_right = ending[welding.size - 1][:x] + welding.last["r"] * box.cap
    l_left = ending[welding.size][:x] + llc.first["l"] * box.cap
    assert_in_delta 0.4305, lettering.dig("spaces", "WELDING LLC"), 1e-9, "measured from the kit PNG: 39.61 px at a 92 px cap height"
    assert_in_delta 0.4305 * box.cap, l_left - g_right, 1e-9, "inside the ending, the kit's own space"
    assert_in_delta ending.last[:x] + llc.last["r"] * box.cap, box.width, 1e-9

    { first: ["#D7602E"] * 10 + ["#2D5E8E"] * 10, second: ["#2D5E8E"] * 10 + ["#D7602E"] * 10 }.each do |text, fills|
      assert_equal fills, letters(logo.svg(text:)).map { |p| p["fill"] }, "#{text}: the whole ending leads or follows as one"
    end
    assert_equal ["COMMERCIAL", "WELDING"], Logo.new("x", styles: welding_style(name: "COMMERCIAL WELDING")).words, "an ending of one traced word"
  end

  def test_a_name_set_in_a_font_is_still_exactly_two_words
    assert_match(/exactly two words, got 3/, refusal { Logo.new("x", styles: { "x" => Logo.styles.fetch("studio").merge("name" => "McRITCHIE STUDIO LABS") }) })
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
    assert_in_delta box.cap / 2, left2 - right1, 1e-9, "the word gap starts at the ink, with no trailing tracking step"
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
    assert_equal [8, 13, 6 * 95, 20], [Logo.icons.size, layers.size, glyphs.size, traced.size]

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
    [HOSTILE, "M0,0 L1,1 Z\n", "\nM0,0", %("), %(M0,0"), "M0,0 url(#x)", "M0,0<", "M0 0 & L1 1", nil, 7, ["M0,0"]].each do |d|
      refuse.(/icon studio layer "primary" has a path that is not SVG path data/, d) { |icon| icon["layers"][0]["d"] = d }
    end
    ["evenodd\n", %(evenodd"/><script>), "EVENODD", "", nil, "inherit"].each do |rule|
      refuse.(/icon studio layer "primary" has fill rule .*expected nonzero or evenodd/m, rule) { |icon| icon["layers"][0]["fill_rule"] = rule }
    end
    [%(translate(1,2)"><script>), "translate(1,2)\n", "\ntranslate(1,2)", "skewX(3)", "translate(a)", "translate()", "url(#x)", "", " scale(2)", "scale(2) ",
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
      assert_match(/a letter of "WELDING LLC" has a path that is not SVG path data/, refusal { Logo.new("welding", letterings: hostile) }, d.inspect)
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

  def test_a_watermark_is_the_whole_logo_in_one_fill_inside_one_translucent_group
    Logo.brands.each do |brand|
      logo = Logo.new(brand)
      Logo::RULES.keys.product(Logo::TEXTS).each do |rule, text|
        svg = logo.svg(rule:, text:, tone: :watermark)
        xml = doc(svg)
        assert_empty xml.errors
        assert_equal %w[g path svg], xml.xpath("//*").map(&:name).uniq.sort, "#{brand}: still paths only"
        group = xml.root.element_children
        assert_equal [["g", "0.6"]], group.map { |g| [g.name, g["opacity"]] }, "#{brand}: one group carries the opacity"
        assert_equal 1, svg.scan("opacity").size, "#{brand}: no path or inner group has an opacity of its own"
        paths = xml.css("path")
        assert_equal ["#FFFFFF"], paths.map { |p| p["fill"] }.uniq, "#{brand} rule #{rule} #{text}: every path takes the one fill"
        assert_equal paths.size, group.first.css("path").size, "#{brand}: every path is inside the group"
        assert_equal doc(logo.svg(rule:, text:, tone: :light)).root["viewBox"], xml.root["viewBox"], "#{brand} rule #{rule} #{text}: the light logo's box"
        assert_equal logo.layout(rule:, text:, tone: :light).to_h, logo.layout(rule:, text:, tone: :watermark).to_h
      end
    end
  end

  def test_a_watermark_draws_a_single_colour_icon_where_the_brand_names_one
    icon_paths = ->(brand) { doc(Logo.new(brand).svg(tone: :watermark)).css("path:not([transform])").map { |p| [p["d"], p["fill-rule"]] } }
    layers = ->(key) { Logo.icons.fetch(key).fetch("layers").map { |layer| [layer["d"], layer["fill_rule"]] } }
    # Turf Monster's three-layer head in one fill is a solid blob: its watermark must be the linework icon.
    assert_equal layers.("turf_mono"), icon_paths.("turf")
    assert_equal 1, icon_paths.("turf").size
    refute_includes Logo.icons.fetch("turf").fetch("layers").map { |layer| layer["d"] }, icon_paths.("turf").first.first
    assert_equal layers.("welding_mono"), icon_paths.("welding")
    # A brand that names none keeps its own icon, every layer in the one fill.
    assert_equal layers.("studio"), icon_paths.("studio")
    assert_equal layers.("industries"), icon_paths.("industries")
    assert_equal 2, icon_paths.("industries").size

    plain = { "x" => Logo.styles.fetch("turf").except("watermark") }
    assert_equal layers.("turf"), doc(Logo.new("x", styles: plain).svg(tone: :watermark)).css("path:not([transform])").map { |p| [p["d"], p["fill-rule"]] }
    missing = { "x" => Logo.styles.fetch("turf").merge("watermark" => { "icon_key" => "anvil" }) }
    assert_match(/no icon "anvil" in the icon data/, refusal { Logo.new("x", styles: missing) })
    hostile = icons_with("turf_mono") { |icon| icon["layers"][0]["d"] = HOSTILE }
    assert_match(/icon turf_mono layer "primary" has a path/, refusal { Logo.new("turf", icons: hostile) })
  end

  def test_a_watermark_keeps_the_weights_and_loses_the_colours
    weights = ->(text) { letters(industries.svg(text:, tone: :watermark)).map { |p| p["d"] } }
    assert_equal letters(industries.svg(text: :first)).map { |p| p["d"] }, weights.(:first)
    assert_equal 3, Logo::TEXTS.map(&weights).uniq.size, "a brand that leads by weight still has three texts"

    %w[turf welding].each do |brand|
      logo = Logo.new(brand)
      assert_equal "colour", logo.highlight
      assert_equal 1, Logo::TEXTS.map { |text| logo.svg(text:, tone: :watermark) }.uniq.size, "#{brand} leads by colour: one colour, one watermark"
    end
    assert_equal %w[weight weight], [industries.highlight, Logo.new("studio").highlight]
  end

  def test_a_watermarks_guides_are_drawn_at_full_strength_outside_the_group
    xml = doc(industries.svg(rule: 4, text: :second, tone: :watermark, guides: true))
    xml.remove_namespaces!
    assert_equal [%w[g guide-ghosts], ["g", nil], %w[g guide-lines]], xml.root.element_children.map { |g| [g.name, g["class"]] }
    assert_equal "0.6", xml.root.element_children[1]["opacity"]
    assert_equal %w[line] * 7 + %w[text] * 4 + (%w[line] * 3 + %w[text]) * 2, xml.at_css("g.guide-lines").element_children.map(&:name)
    assert_empty xml.css("g[opacity='0.6'] line, g[opacity='0.6'] text, g[opacity='0.6'] g.guide-ghosts")
    assert_equal doc(industries.svg(rule: 4, text: :second, guides: true)).root["viewBox"], xml.root["viewBox"]
    assert_equal [Logo::GUIDE], xml.css("line").map { |l| l["stroke"] }.uniq
  end

  def test_a_style_may_set_the_watermarks_fill_and_opacity_and_a_bad_one_is_refused
    mark = ->(value) { studio_style(watermark: value) }
    xml = doc(Logo.new("x", styles: mark.({ "fill" => "#102030", "opacity" => 0.25 })).svg(tone: :watermark))
    assert_equal ["0.25", ["#102030"]], [xml.root.element_children.first["opacity"], xml.css("path").map { |p| p["fill"] }.uniq]
    assert_equal "1", doc(Logo.new("x", styles: mark.({ "opacity" => 1 })).svg(tone: :watermark)).root.element_children.first["opacity"]
    assert_equal Logo.new("studio").svg(tone: :watermark), Logo.new("x", styles: mark.({})).svg(tone: :watermark), "an empty map is the defaults"
    assert_equal Logo.new("studio").svg(tone: :dark), Logo.new("x", styles: mark.({ "fill" => "#102030" })).svg(tone: :dark), "the map touches no other tone"

    [0, 0.0, -0.1, 1.01, 1.0000001, 2, "0.5", nil, true, Float::NAN, Float::INFINITY, [0.5]].each do |opacity|
      message = refusal { Logo.new("x", styles: mark.({ "opacity" => opacity })) }
      assert_match(/watermark opacity must be a number greater than 0 and at most 1, got/, message, opacity.inspect)
    end
    [%(#FFF"/><script>), "#FFFFFF\n", "\n#FFFFFF", "white", nil, 7].each do |fill|
      assert_match(/is not a #hex colour/, refusal { Logo.new("x", styles: mark.({ "fill" => fill })) }, fill.inspect)
    end
    ["#FFFFFF", ["fill"], { "colour" => "#FFFFFF" }, { "fill" => "#FFFFFF", "blur" => 2 }].each do |value|
      assert_match(/watermark must be a map of fill, opacity, icon_key, got/, refusal { Logo.new("x", styles: mark.(value)) }, value.inspect)
    end
  end

  # Task stacked-tagline-and-ghost-grid: the rule-of-thirds reel's ghost copies of the name.
  def test_guides_stack_ghost_copies_of_the_name_one_per_row_numbered
    Logo.brands.product(Logo::RULES.keys, Logo::TONES).each do |brand, rule, tone|
      logo = Logo.new(brand)
      box = logo.layout(rule:, text: :second, tone:)
      plain = logo.svg(rule:, text: :second, tone:)
      svg = logo.svg(rule:, text: :second, tone:, guides: true)
      xml = doc(svg).remove_namespaces!
      where = "#{brand} rule #{rule} #{tone}"
      assert_includes svg, plain[%r{<svg[^>]*>(.*)</svg>}, 1], "#{where}: the logo itself, to the byte"
      ghosts, *logo_part, lines = xml.root.element_children.to_a
      assert_equal "guide-ghosts", ghosts["class"], "#{where}: the ghosts first, behind the logo"
      assert_equal "guide-lines", lines["class"], where
      assert_equal [nil], logo_part.map { |node| node["class"] }.uniq, where
      assert_equal Logo::GHOST_OPACITY.fetch(tone).to_s, ghosts["opacity"], where
      assert_operator ghosts["opacity"].to_f, :<, 0.4, where
      text = tone == :watermark ? "#FFFFFF" : Logo.styles.fetch(brand).fetch("tones").fetch(tone.to_s).fetch("text")
      assert_equal [text], ghosts.css("path").map { |p| p["fill"] }.uniq, "#{where}: the logo's own text colour, never the guide magenta"
      refute_includes ghosts.to_xml, Logo::GUIDE, where

      copies = ghosts.css("path").group_by { |p| p["transform"][/,([-\d.]+)\)/, 1] }
      rows = rule == 3 ? [1, 3] : (1..rule).to_a
      assert_equal rows.map { |row| format("%.2f", row * box.row) }, copies.keys, "#{where}: one copy per row the real name does not fill"
      named = box.letters.count { |l| !l[:d].empty? }
      copies.each_value do |copy|
        assert_equal [named, format("scale(%.4f)", box.row)], [copy.size, copy.map { |p| p["transform"][/scale.*/] }.uniq.first], "#{where}: the whole name, one row tall"
        x = copy.first["transform"][/translate\(([-\d.]+),/, 1].to_f
        assert_in_delta box.name_left + (box.letters.first[:x] - box.name_left) * box.row / box.cap, x, 0.01, "#{where}: starts where the name's ink does"
      end
      assert_equal (1..rule).map(&:to_s) + %w[½ ½], lines.css("text").map(&:text), "#{where}: numbered 1-#{rule}, and the two gaps"
      assert_equal ["1.0"], lines.css("line").map { |l| l["stroke-width"] }.uniq, "#{where}: thinner than the 1.5 before"
      assert_equal [rule == 6 ? "40" : "30"], lines.css("text").map { |t| t["font-size"] }.uniq, "#{where}: smaller than the 32 before; the rule of 6's larger, to fit its plate"
    end
  end
end
