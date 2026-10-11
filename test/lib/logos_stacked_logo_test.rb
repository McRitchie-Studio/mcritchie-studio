# frozen_string_literal: true

# [unit] Logos::StackedLogo (task logo-tabs-icon-and-stacked): the 3-2-1
# geometry of the two-line and the one-line form, the computed tracking, the
# text versions and tones it shares with the Navbar Logo, the guide drawing,
# the vector-only output, and the refusals.

require "digest"
require "minitest/autorun"
require "nokogiri"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"

class LogosStackedLogoTest < Minitest::Test
  Stacked = Logos::StackedLogo
  Navbar = Logos::NavbarLogo
  U = Stacked::U
  # Width / height, from the prototype (earlier-labs/ms_gen_vertical.py) and the closed forms 3n / (1.8n + 8) and,
  # for the one-line form, 3n / (1.8n + 5), where n is the big line's ink width in cap heights.
  RATIOS = {
    ["studio", :first] => 1.078, ["studio", :homogeneous] => 1.078, ["studio", :second] => 1.056,
    ["industries", :first] => 1.073, ["industries", :homogeneous] => 1.073, ["industries", :second] => 1.056
  }.freeze

  # SHA-256 over every stacked logo WITHOUT guides in its brand's own form (3 texts x 3 tones each, "<key>\n<svg>") and
  # every icon (4 brands x 3 tones). The single digest over all four brands (6b40237f…, taken on `accepted` at 4368b9183)
  # was split by task navbar-spacing-and-rotated-guides, when item 4c gave the one-line name the Navbar Logo's new word
  # gap: the two-line brands' digest was taken BEFORE that change and still holds, so they did not move by a byte; Turf
  # Monster's one-line logos and every tagline-form logo were re-taken deliberately after it.
  TWO_LINE_DIGEST = "f066b3ee448c37018089636ee6d7c9f5bad5213551a5c88a7322eb2ecd9e3be4"
  ONE_LINE_DIGEST = "b21a2b809641dfc8f3c5084a2a1550540e8ba0d222952ebaadb4c50a5822d1ae"
  TAGLINE_DIGEST = "cc5f5a64a6534e759b48f85a152d939e594b518de1593b3b9e33328264ca831d"
  ICON_DIGEST = "4196eaad2022f4866444301ed821104d48a6f06f793fbd95b90e7fe4c86d2c58"
  # Width / height of the tagline form, measured (task stacked-tagline-and-ghost-grid). Each equals 3n / (1.8n + 8), n the
  # name's ink width in cap heights: the tagline form is as tall as the two-line form (icon 0.6W, then 2u, 3u, 2u, 1u).
  # Re-measured when task navbar-spacing-and-rotated-guides made the word gap half a cap height (it sets the name as
  # the one-line form does). Before: studio 1.2708 / 1.2645 / 1.2609, industries 1.3270 / 1.3214 / 1.3215, welding 1.2838.
  TAGLINE_RATIOS = {
    ["studio", :homogeneous] => 1.2736, ["studio", :first] => 1.2674, ["studio", :second] => 1.2638,
    ["industries", :homogeneous] => 1.3290, ["industries", :first] => 1.3235, ["industries", :second] => 1.3236,
    ["welding", :homogeneous] => 1.2867, ["welding", :first] => 1.2867, ["welding", :second] => 1.2867
  }.freeze
  TAGLINES = { "studio" => "BUILD SMARTER", "industries" => "BUILD BETTER", "welding" => "BUILDING STRONG CONNECTIONS", "turf" => nil }.freeze

  def stacked(brand) = (@stacked ||= {})[brand] ||= Stacked.new(brand)
  def doc(svg) = Nokogiri::XML(svg) { |config| config.strict }
  def refusal(&) = assert_raises(Navbar::Error, &).message
  def style(brand, **changes) = { "x" => Navbar.styles.fetch(brand).merge(changes.transform_keys(&:to_s)) }
  def glyph(char, weight) = Navbar.glyphs.fetch(weight.to_s).fetch("glyphs").fetch(char)

  # [left ink edge, right ink edge] of a run of placed letters set from `glyphs` (same order).
  def ink(placed, glyphs)
    [placed.first[:x] + glyphs.first["l"] * placed.first[:cap], placed.last[:x] + glyphs.last["r"] * placed.last[:cap]]
  end

  def test_the_box_matches_the_prototype_and_the_closed_form
    RATIOS.each do |(brand, text), ratio|
      box = stacked(brand).layout(text:)
      assert_in_delta ratio, box.width / box.height, 0.01, "#{brand} #{text}"
      _, _, width, height = doc(stacked(brand).svg(text:)).root["viewBox"].split.map(&:to_f)
      assert_in_delta ratio, width / height, 0.01, "#{brand} #{text} viewBox"
    end
    Navbar::TEXTS.each do |text|
      box = stacked("turf").layout(text:)
      assert_in_delta 1.28, box.width / box.height, 0.02, "turf #{text}"
      assert_in_delta 3 * (box.width / (3 * U)) / (1.8 * (box.width / (3 * U)) + 5), box.width / box.height, 1e-9, "turf #{text}: the one-line closed form"
    end
  end

  def test_welding_meets_the_closed_form_on_its_own_letterings_width
    word = Navbar.letterings.fetch("welding").fetch("words").fetch("COMMERCIAL")
    n = word[0...-1].sum { |letter| letter["adv"] } + word.last["r"] - word.first["l"]   # the big line's ink width in cap heights
    Navbar::TEXTS.each do |text|
      box = stacked("welding").layout(text:)
      assert_in_delta n * 3 * U, box.width, 1e-9, text
      assert_in_delta 3 * n / (1.8 * n + 8), box.width / box.height, 1e-9, text
    end
  end

  def test_two_lines_stack_as_icon_2u_big_line_3u_2u_small_line_1u
    box = stacked("studio").layout(text: :first)
    assert_equal :two_line, box.form
    big = "McRITCHIE".chars.map { |char| glyph(char, 800) }
    assert_in_delta big[0...-1].sum { |g| g["adv"] } * 3 * U + (big.last["r"] - big.first["l"]) * 3 * U, box.width, 1e-9, "the big line's ink is the width"
    assert_in_delta 0.6 * box.width, box.icon_height, 1e-9
    top = box.icon_height
    assert_equal [0, top, top + 2 * U, top + 5 * U, top + 7 * U, top + 8 * U], box.edges
    assert_in_delta 0.6 * box.width + 8 * U, box.height, 1e-9

    first, second = box.letters.partition { |letter| letter[:word].zero? }
    assert_equal [[top + 5 * U, 3 * U]], first.map { |l| [l[:baseline], l[:cap]] }.uniq, "the big line: capitals 3u, on the fourth edge"
    assert_equal [[top + 8 * U, U]], second.map { |l| [l[:baseline], l[:cap]] }.uniq, "the small line: capitals 1u, on the last edge"
    left, right = ink(first, big)
    assert_in_delta 0, left, 1e-9
    assert_in_delta box.width, right, 1e-9

    paths = doc(stacked("studio").svg(text: :first)).css("path[transform]")
    assert_equal ["scale(120.0000)"] * 9 + ["scale(40.0000)"] * 6, paths.map { |p| p["transform"][/scale.*/] }
    assert_equal [format("%.2f", top + 5 * U)] * 9 + [format("%.2f", top + 8 * U)] * 6, paths.map { |p| p["transform"][/,([\d.]+)\)/, 1] }
  end

  def test_the_small_line_is_tracked_between_letters_to_60_percent_and_centred
    { "studio" => [:first, 300], "industries" => [:second, 700] }.each do |brand, (text, weight)|
      box = stacked(brand).layout(text:)
      small = box.letters.select { |letter| letter[:word] == 1 }
      glyphs = stacked(brand).words[1].chars.map { |char| glyph(char, weight) }
      left, right = ink(small, glyphs)
      assert_in_delta 0.6 * box.width, right - left, 1e-9, "#{brand}: 60% of the big line"
      assert_in_delta box.icon_height, right - left, 1e-9, "#{brand}: the icon is as tall as the small line is wide"
      assert_in_delta box.width / 2, (left + right) / 2, 1e-9, "#{brand}: centred, so nothing trails the last letter"

      steps = small.each_cons(2).zip(glyphs).map { |(a, b), g| (b[:x] - a[:x]) / U - g["adv"] }
      assert_operator steps.min, :>, 0, "#{brand}: tracked out, never in"
      steps.each { |step| assert_in_delta steps.first, step, 1e-9, "#{brand}: the same space between every pair" }
      natural = glyphs[0...-1].sum { |g| g["adv"] } + glyphs.last["r"] - glyphs.first["l"]
      assert_in_delta (0.6 * box.width / U - natural) / (glyphs.size - 1), steps.first, 1e-9, brand
    end
  end

  def test_the_one_line_form_sets_the_whole_name_as_the_navbar_logo_does
    box = stacked("turf").layout(text: :second)
    assert_equal :one_line, box.form
    assert_equal :one_line, stacked("turf").form
    assert_in_delta 0.6 * box.width, box.icon_height, 1e-9
    assert_equal [0, box.icon_height, box.icon_height + 2 * U, box.icon_height + 5 * U], box.edges
    assert_in_delta 0.6 * box.width + 5 * U, box.height, 1e-9
    assert_equal [[box.height, 3 * U]], box.letters.map { |l| [l[:baseline], l[:cap]] }.uniq, "one line, capitals 3u"

    navbar = Navbar.new("turf").layout(rule: 4, text: :second)
    scale = 3 * U / navbar.cap
    assert_equal 11, box.letters.size
    box.letters.zip(navbar.letters).each do |mine, theirs|
      assert_equal [theirs[:d], theirs[:word]], [mine[:d], mine[:word]]
      assert_in_delta (theirs[:x] - navbar.name_left) * scale, mine[:x], 1e-6, "the brand's tracking and word gap, at this size"
    end
    assert_in_delta (navbar.width - navbar.name_left) * scale, box.width, 1e-6
  end

  def test_everything_is_centred_and_the_icon_is_scaled_to_its_height
    Navbar.brands.product(Navbar::TONES).each do |brand, tone|
      box = stacked(brand).layout(text: :first, tone:)
      key = { %w[welding dark] => "welding_mono", %w[welding watermark] => "welding_mono", %w[turf watermark] => "turf_mono" }.fetch([brand, tone.to_s], brand)
      icon = Navbar.icons.fetch(key)
      icon_width = icon["w"] * box.icon_height / icon["h"]
      assert_in_delta (box.width - icon_width) / 2, box.icon_left, 1e-9, "#{brand} #{tone}"

      root = doc(stacked(brand).svg(text: :first, tone:)).root
      group = tone == :watermark ? root.element_children.first.element_children.first : root.element_children.first
      assert_equal format("translate(%.2f,0)", box.icon_left), group["transform"], "#{brand} #{tone}"
      assert_equal format("scale(%.5f)", box.icon_height / icon["h"]), group.element_children.first["transform"], "#{brand} #{tone}"
      assert_equal icon.fetch("layers").map { |l| l["d"] }, group.css("path").map { |p| p["d"] }, "#{brand} #{tone}"
    end
  end

  def test_text_versions_and_tones_take_the_navbar_logos_weights_and_fills
    Navbar.brands.product(Navbar::TEXTS, Navbar::TONES).each do |brand, text, tone|
      mine = doc(stacked(brand).svg(text:, tone:))
      theirs = doc(Navbar.new(brand).svg(rule: 4, text:, tone:))
      look = ->(xml, css) { xml.css(css).map { |p| [p["d"], p["fill"], p["fill-rule"]] } }
      where = "#{brand} #{text} #{tone}"
      assert_equal look.(theirs, "path[transform]"), look.(mine, "path[transform]"), "#{where}: the same letters in the same fills"
      assert_equal look.(theirs, "path:not([transform])"), look.(mine, "path:not([transform])"), "#{where}: the same icon layers and fills"
      assert_operator look.(mine, "path[transform]").size, :>=, 11, where
    end
  end

  def test_a_logo_without_guides_is_paths_only_in_its_own_box
    Navbar.brands.product(Navbar::TEXTS, Navbar::TONES).each do |brand, text, tone|
      svg = stacked(brand).svg(text:, tone:)
      xml = doc(svg)
      box = stacked(brand).layout(text:, tone:)
      where = "#{brand} #{text} #{tone}"
      assert_empty xml.errors, where
      assert_equal %w[g path svg], xml.xpath("//*").map(&:name).uniq.sort, where
      refute_match(/href|url\(|@font-face|<style|data:|<text|<image|<line/, svg, where)
      assert_equal format("0 0 %.2f %.2f", box.width, box.height), xml.root["viewBox"], where
      assert_equal [format("%.2f", box.width), format("%.2f", box.height)], [xml.root["width"], xml.root["height"]], where
    end
    assert_equal stacked("studio").svg, stacked("studio").svg(text: :homogeneous, tone: :light, guides: false), "the defaults"
  end

  def test_a_watermark_is_one_fill_inside_one_translucent_group
    Navbar.brands.each do |brand|
      svg = stacked(brand).svg(text: :first, tone: :watermark)
      xml = doc(svg)
      assert_equal [["g", "0.6"]], xml.root.element_children.map { |node| [node.name, node["opacity"]] }, brand
      assert_equal 1, svg.scan("opacity").size, brand
      assert_equal ["#FFFFFF"], xml.css("path").map { |p| p["fill"] }.uniq, brand
    end
  end

  # Every guide drawing: [brand, form, tone].
  def guided = Navbar.brands.flat_map { |brand| stacked(brand).forms.product(Navbar::TONES).map { |form, tone| [brand, form, tone] } }

  def ghost_fill(brand, tone) = tone == :watermark ? "#FFFFFF" : Navbar.styles.fetch(brand).fetch("tones").fetch(tone.to_s).fetch("text")

  # The ruler's copies, by baseline: { baseline => letters drawn at 1u right of the logo }.
  def ruler_rows(xml, box)
    xml.css("g.guide-ghosts > path").select { |p| p["transform"][/translate\(([-\d.]+),/, 1].to_f > box.width }
       .group_by { |p| p["transform"][/,([-\d.]+)\)/, 1].to_f }
  end

  def test_guides_are_the_logo_untouched_then_a_ghost_group_then_a_line_group
    guided.each do |brand, form, tone|
      where = "#{brand} #{form} #{tone}"
      plain = stacked(brand).svg(form:, tone:, text: :first)
      svg = stacked(brand).svg(form:, tone:, text: :first, guides: true)
      xml = doc(svg).remove_namespaces!
      assert_includes svg, plain[/<svg[^>]*>(.*)<\/svg>/, 1], "#{where}: the logo itself, to the byte"
      ghosts, lines = xml.root.element_children.to_a.last(2)
      assert_equal [["g", "guide-ghosts"], ["g", "guide-lines"]], [ghosts, lines].map { |g| [g.name, g["class"]] }, where
      assert_equal Stacked::GHOST_OPACITY.fetch(tone).to_s, ghosts["opacity"], where
      assert_operator ghosts["opacity"].to_f, :<, 0.4, "#{where}: the ghosts are faint"
      assert_equal [ghost_fill(brand, tone)], ghosts.css("path").map { |p| p["fill"] }.uniq, "#{where}: the logo's own text colour"
      refute_includes svg[svg.index('<g class="guide-ghosts"')..svg.index('<g class="guide-lines"')], Stacked::GUIDE, "#{where}: no ghost in the guide magenta"
      assert_equal %w[line text], lines.element_children.map(&:name).uniq.sort, "#{where}: lines and numbers only"
      assert_equal [Stacked::GUIDE], (lines.css("line").map { |l| l["stroke"] } + lines.css("text").map { |t| t["fill"] }).uniq, where
      assert_equal ["1.0"], lines.css("line").map { |l| l["stroke-width"] }.uniq, "#{where}: thinner than the 1.5 before"
      assert_empty xml.css("g[opacity] g.guide-ghosts, g[opacity] g.guide-lines"), "#{where}: never inside a watermark's group"
    end
  end

  def test_the_ruler_stacks_one_copy_of_the_small_line_per_unit_numbered_in_each_band
    { "studio" => [:two_line, "STUDIO"], "industries" => [:tagline, "BUILD BETTER"], "welding" => [:tagline, "BUILDING STRONG CONNECTIONS"],
      "turf" => [:one_line, "Turf Monster"] }.each do |brand, (form, line)|
      box = stacked(brand).layout(form:, text: :first)
      xml = doc(stacked(brand).svg(form:, text: :first, guides: true)).remove_namespaces!
      rows = ruler_rows(xml, box)
      bands = form == :one_line ? [2, 3] : [2, 3, 2, 1]
      tops = box.edges.drop(1)
      expected = bands.zip(tops).flat_map { |size, top| (1..size).map { |row| (top + row * U).round(2) } }
      assert_equal expected, rows.keys.sort, "#{brand}: a copy on every unit from the icon's foot to the logo's foot, edge to edge"
      assert_in_delta box.height, rows.keys.max, 0.01, brand
      rows.each_value do |copy|
        assert_equal [format("scale(%.4f)", U)], copy.map { |p| p["transform"][/scale.*/] }.uniq, "#{brand}: each copy is 1u"
        assert_equal line.delete(" ").size, copy.size, "#{brand}: the whole small line"
      end
      numbers = xml.css("g.guide-lines text").map(&:text)
      assert_equal ["1"] + bands.flat_map { |size| (1..size).map(&:to_s) }, [numbers.last] + numbers[0...-1], "#{brand}: 1-2, 1-2-3, 1-2, 1, and the icon's 1"
    end
  end

  # Item 4a (task navbar-spacing-and-rotated-guides): the ruler's copies were set untracked, so each was narrower than
  # the real small line. Each copy is now the small line exactly as the logo sets it, and exactly as wide.
  def test_each_ruler_copy_is_the_small_line_with_its_tracking_and_as_wide
    guided.each do |brand, form, tone|
      box = stacked(brand).layout(form:, tone:, text: :second)
      xml = doc(stacked(brand).svg(form:, tone:, text: :second, guides: true)).remove_namespaces!
      where = "#{brand} #{form} #{tone}"
      real = small_line(box).reject { |l| l[:d].empty? }
      real_width = box.line_width * real.first[:cap]
      assert_in_delta(form == :one_line ? box.width : 0.6 * box.width, real_width, 1e-6, "#{where}: the real small line's ink width")
      ruler_rows(xml, box).each do |baseline, copy|
        assert_equal real.map { |l| l[:d] }, copy.map { |p| p["d"] }, "#{where} #{baseline}: the whole small line"
        xs = copy.map { |p| translate(p).first }
        real.zip(xs).each do |letter, x|
          assert_in_delta (letter[:x] - real.first[:x]) * U / letter[:cap], x - xs.first, 0.02, "#{where}: the same steps as the real line, at 1u"
        end
        ink = box.line.reject { |l| l[:d].empty? }
        copy_width = xs.last + ink.last[:r] * U - (xs.first + ink.first[:l] * U)
        assert_in_delta real_width * U / real.first[:cap], copy_width, 0.02, "#{where}: as wide as the real line at 1u"
        assert_in_delta box.width + Stacked::RULER_X, xs.first + ink.first[:l] * U, 0.02, "#{where}: from the ruler's left edge"
      end
    end
  end

  def icon_box(brand, tone, box)
    key = { %w[welding dark] => "welding_mono", %w[welding watermark] => "welding_mono", %w[turf watermark] => "turf_mono" }.fetch([brand, tone.to_s], brand)
    icon = Navbar.icons.fetch(key)
    [box.icon_left, 0, box.icon_left + icon["w"] * box.icon_height / icon["h"], box.icon_height]
  end

  def translate(node) = node["transform"][/translate\(([-\d.]+),([-\d.]+)\)/, 0].then { |t| t.scan(/[-\d.]+/).map(&:to_f) }

  # The small line as the logo itself draws it: the second word, the tagline, or in the one-line form the whole name.
  def small_line(box) = box.letters.select { |l| { two_line: [1], tagline: [2], one_line: [0, 1] }.fetch(box.form).include?(l[:word]) }

  # Item 4a (task navbar-spacing-and-rotated-guides): Alex's annotated screenshot asked for the line ITSELF, spaced
  # exactly as in the logo, turned 90 degrees beside the icon, not its letters spelled downwards in a column. Review
  # of PR 2042 (Carl, activity-17641) still holds: it stands beside the icon, on the plate, never on the icon.
  def test_the_small_line_turned_on_end_spans_the_icon_beside_it
    guided.each do |brand, form, tone|
      box = stacked(brand).layout(form:, tone:, text: :first)
      xml = doc(stacked(brand).svg(form:, tone:, text: :first, guides: true)).remove_namespaces!
      where = "#{brand} #{form} #{tone}"
      proof = xml.css("g.guide-ghosts > g.guide-proof")
      assert_equal 1, proof.size, "#{where}: one turned copy, inside the ghosts' translucent group"
      x, y = translate(proof.first)
      assert_match(/\Atranslate\([-\d.]+,[-\d.]+\) rotate\(-90\)\z/, proof.first["transform"], "#{where}: a quarter turn, so it reads bottom to top")
      left, top, _, bottom = icon_box(brand, tone, box)
      assert_in_delta left - Stacked::PROOF_GAP, x, 0.01, "#{where}: its baseline half a unit left of the icon's box"
      assert_in_delta bottom, y, 0.01, "#{where}: it starts at the icon's foot"

      real = small_line(box)
      paths = proof.first.css("path")
      assert_equal real.map { |l| l[:d] }.reject(&:empty?), paths.map { |p| p["d"] }, "#{where}: the small line's letters, in order"
      cap = paths.map { |p| p["transform"][/scale\(([\d.]+)\)/, 1].to_f }.uniq
      assert_equal 1, cap.size, where
      cap = cap.first
      expected_cap = form == :one_line ? 0.6 * 3 * U : U
      assert_in_delta expected_cap, cap, 0.01, "#{where}: #{form == :one_line ? 'the name at 60% of its size' : 'the small line at its own 1u'}"
      inked = real.reject { |l| l[:d].empty? }
      scale = cap / inked.first[:cap]
      paths.zip(inked).each do |path, letter|
        assert_in_delta (letter[:x] - inked.first[:x]) * scale, translate(path).first - translate(paths.first).first, 0.02,
                        "#{where}: the logo's own spacing, tracking and word gap included"
      end
      ends = box.line.reject { |l| l[:d].empty? }.then { |run| [run.first[:x] + run.first[:l], run.last[:x] + run.last[:r]] }
      assert_in_delta 0, ends.first * cap, 0.01, "#{where}: its first letter's ink is on the icon's foot"
      assert_in_delta bottom - top, ends.last * cap, 0.01, "#{where}: its last letter's ink is on the icon's top: as long as the icon is tall"
      assert_operator x, :<, left, "#{where}: on the plate, never over the icon"

      lines = xml.css("g.guide-lines line")
      bands, rest = lines.partition { |l| l["x1"] == "-20.00" }
      assert_equal box.edges.map { |edge| format("%.2f", edge) }, bands.map { |l| l["y1"] }, "#{where}: a line at each band boundary"
      bracket_x = x - cap - Stacked::BRACKET_GAP
      expected = [[box.width / 2, -20, box.width / 2, box.height + 20], [bracket_x, 0, bracket_x, box.icon_height],
                  [bracket_x, 0, bracket_x + Stacked::TICK, 0], [bracket_x, box.icon_height, bracket_x + Stacked::TICK, box.icon_height]]
      assert_equal expected.size, rest.size, where
      expected.zip(rest).each do |line, drawn|
        line.zip(%w[x1 y1 x2 y2].map { |k| drawn[k].to_f }).each do |want, got|
          assert_in_delta want, got, 0.02, "#{where}: the centre line, and a bracket ticked at the icon's top and foot"
        end
      end
      assert_operator bands.first["x2"].to_f, :>, ruler_rows(xml, box).values.flatten.map { |p| p["transform"][/translate\(([-\d.]+),/, 1].to_f }.max, "#{where}: across the ruler"
      label = xml.css("g.guide-lines text").last
      assert_equal ["1", format("%.2f", box.width / 2 + 10), "-10.00"], [label.text, label["x"], label["y"]], "#{where}: a 1 at the icon's top"
      _, _, width, = xml.root["viewBox"].split.map(&:to_f)
      assert_operator xml.root["viewBox"].split.first.to_f, :<=, bracket_x - 20, "#{where}: the bracket is inside the drawing"
      assert_operator width, :>, box.width, where
    end
  end

  def test_the_line_is_the_small_line_at_a_cap_of_one
    { ["studio", :two_line] => 1, ["industries", :tagline] => 2, ["turf", :one_line] => nil }.each do |(brand, form), word|
      box = stacked(brand).layout(form:, text: :second)
      real = small_line(box)
      assert_equal real.map { |l| l[:d] }, box.line.map { |l| l[:d] }, brand
      first = real.first
      box.line.zip(real).each { |mine, theirs| assert_in_delta (theirs[:x] - first[:x]) / theirs[:cap], mine[:x] - box.line.first[:x], 1e-9, brand }
      assert_in_delta 0, box.line.first[:x] + box.line.first[:l], 1e-9, "#{brand}: its ink starts at 0"
      width = form == :one_line ? box.width / (3 * U) : 0.6 * box.width / U
      assert_in_delta width, box.line_width, 1e-9, "#{brand}: the small line's ink width, at a cap of 1"
      assert(word.nil? || real.all? { |l| l[:word] == word }, brand)
    end
  end

  def test_the_guide_drawing_reaches_past_the_ruler
    box = stacked("industries").layout(text: :first)
    xml = doc(stacked("industries").svg(text: :first, guides: true))
    right = Stacked::RULER_X + box.line_width * U + 40
    assert_equal format("-40 -40 %.2f %.2f", box.width + 40 + right, box.height + 80), xml.root["viewBox"], "the column fits in the usual pad"
  end

  def test_a_second_word_too_wide_to_track_is_refused_by_name_never_drawn_tighter
    message = refusal { Stacked.new("x", styles: style("turf", stacked: "two_line")) }
    assert_equal "brand x: the second word \"Monster\" cannot be tracked out to 60% of the first word's width (it is 68% already): " \
                 "set `stacked: one_line` in the brand's style", message
    assert_match(/cannot be tracked out/, refusal { Stacked.new("x", styles: { "x" => Navbar.styles.fetch("turf").except("stacked") }) },
                 "two lines unless the style says otherwise")
    assert_match(/second word "A" cannot be tracked out .* \(it has one letter\): set `stacked: one_line`/,
                 refusal { Stacked.new("x", styles: style("studio", name: "McRITCHIE A")) })
    assert_equal :one_line, Stacked.new("x", styles: style("studio", name: "McRITCHIE A", stacked: "one_line")).form
  end

  def test_other_refusals_name_what_is_wrong
    ["stacked", "One_line", 1, true, ["one_line"]].each do |form|
      assert_match(/brand x: stacked must be one of two_line, one_line, got/, refusal { Stacked.new("x", styles: style("studio", stacked: form)) }, form.inspect)
    end
    assert_match(/unknown text :third: expected one of homogeneous, first, second/, refusal { stacked("studio").svg(text: :third) })
    assert_match(/unknown tone :sepia: expected one of light, dark, watermark/, refusal { stacked("studio").svg(tone: :sepia) })
    assert_match(/unknown brand "acme"/, refusal { Stacked.new("acme") })
    assert_equal "a stacked logo takes text, tone, form and guides, not rule: it has no rule", refusal { stacked("studio").svg(rule: 4) }
    assert_equal "a stacked logo takes text, tone and form, not rule: it has no rule", refusal { stacked("studio").layout(rule: 3, text: :first) }
    assert_match(/takes text, tone, form and guides, not rule, weight/, refusal { stacked("studio").svg(tone: :dark, rule: 4, weight: 800) })
    assert_match(/takes text, tone and form, not guides/, refusal { stacked("studio").layout(guides: true) })

    wide = JSON.parse(JSON.generate(Navbar.icons)).tap { |icons| icons.fetch("studio")["w"] = 2000 }
    assert_match(/brand studio: the icon is too wide to stack \(2\.22 of the name's width at this height\)/, refusal { Stacked.new("studio", icons: wide) })
    refute_respond_to stacked("studio"), :examples
    assert_respond_to Navbar.new("studio"), :examples
  end

  def test_every_shipped_brand_stacks_in_the_form_its_style_names
    assert_equal({ "studio" => :two_line, "industries" => :two_line, "turf" => :one_line, "welding" => :two_line },
                 Navbar.brands.to_h { |brand| [brand, stacked(brand).form] })
  end

  def own_form(brands)
    brands.flat_map do |brand|
      Navbar::TEXTS.product(Navbar::TONES).map { |text, tone| "#{brand}-stacked-#{text}-#{tone}\n#{stacked(brand).svg(text:, tone:)}" }
    end
  end

  def test_every_stacked_logo_and_icon_without_guides_is_unchanged_to_the_byte
    two_line = own_form(%w[studio industries welding])
    assert_equal 27, two_line.size
    assert_equal TWO_LINE_DIGEST, Digest::SHA256.hexdigest(two_line.join), "the two-line form, unmoved by the word gap"
    assert_equal ONE_LINE_DIGEST, Digest::SHA256.hexdigest(own_form(%w[turf]).join)
    taglines = TAGLINES.compact.keys.flat_map do |brand|
      Navbar::TEXTS.product(Navbar::TONES).map { |text, tone| "#{brand}-stacked-tagline-#{text}-#{tone}\n#{stacked(brand).svg(form: :tagline, text:, tone:)}" }
    end
    assert_equal 27, taglines.size
    assert_equal TAGLINE_DIGEST, Digest::SHA256.hexdigest(taglines.join)
    icons = Navbar.brands.flat_map { |brand| Navbar::TONES.map { |tone| "#{brand}-icon-#{tone}\n#{Navbar.new(brand).icon_svg(tone:)}" } }
    assert_equal ICON_DIGEST, Digest::SHA256.hexdigest(icons.join)
  end

  # Task stacked-tagline-and-ghost-grid: the tagline is data, in capitals with no full stop.
  def test_each_brand_has_its_tagline_or_none
    assert_equal TAGLINES, Navbar.brands.to_h { |brand| [brand, stacked(brand).tagline] }
    TAGLINES.compact.each_value { |line| assert_equal line.upcase, line and refute line.end_with?(".") }
  end

  def test_a_tagline_with_a_character_the_glyph_data_lacks_or_a_bad_shape_is_refused
    assert_equal "brand x: no glyph for \"Ü\" at weight 500 in the glyph data", refusal { Stacked.new("x", styles: style("studio", tagline: "BÜILD")) }
    ["", " BUILD", "BUILD ", "BUILD  BETTER", "BUILD\nBETTER", 7, ["BUILD"]].each do |line|
      message = refusal { Stacked.new("x", styles: style("studio", tagline: line)) }
      assert_match(/brand x: (tagline must be words separated by single spaces|no glyph for)/, message, line.inspect)
    end
    assert_nil Stacked.new("x", styles: style("studio", tagline: nil)).tagline
  end

  def test_the_tagline_forms_ratio_is_measured_and_meets_the_closed_form
    TAGLINE_RATIOS.each do |(brand, text), ratio|
      box = stacked(brand).layout(text:, form: :tagline)
      n = box.width / (3 * U)
      assert_in_delta ratio, box.width / box.height, 5e-5, "#{brand} #{text}: measured"
      assert_in_delta 3 * n / (1.8 * n + 8), box.width / box.height, 1e-9, "#{brand} #{text}: the closed form"
      _, _, width, height = doc(stacked(brand).svg(text:, form: :tagline)).root["viewBox"].split.map(&:to_f)
      assert_in_delta ratio, width / height, 5e-4, "#{brand} #{text} viewBox"
    end
  end

  def test_the_tagline_form_stacks_icon_2u_name_3u_2u_tagline_1u
    TAGLINE_RATIOS.each_key do |brand, text|
      box = stacked(brand).layout(text:, form: :tagline)
      where = "#{brand} #{text}"
      assert_equal :tagline, box.form, where
      top = box.icon_height
      assert_equal [0, top, top + 2 * U, top + 5 * U, top + 7 * U, top + 8 * U], box.edges, where
      assert_in_delta 0.6 * box.width + 8 * U, box.height, 1e-9, where
      name, line = box.letters.partition { |letter| letter[:word] < 2 }
      assert_equal [[top + 5 * U, 3 * U]], name.map { |l| [l[:baseline], l[:cap]] }.uniq, "#{where}: the name, capitals 3u"
      assert_equal [[top + 8 * U, U, "nonzero"]], line.map { |l| [l[:baseline], l[:cap], l[:fill_rule]] }.uniq, "#{where}: the tagline, capitals 1u"
      assert_equal TAGLINES.fetch(brand).chars.map { |char| glyph(char, 500)["d"] }, line.map { |l| l[:d] }, "#{where}: Montserrat 500"

      glyphs = TAGLINES.fetch(brand).chars.map { |char| glyph(char, 500) }
      left, right = ink(line, glyphs)
      assert_in_delta 0.6 * box.width, right - left, 1e-9, "#{where}: exactly 60% of the name"
      assert_in_delta box.icon_height, right - left, 1e-9, "#{where}: the icon is as tall as the tagline is wide"
      assert_in_delta box.width / 2, (left + right) / 2, 1e-9, "#{where}: centred on the name"
      steps = line.each_cons(2).zip(glyphs).map { |(a, b), g| (b[:x] - a[:x]) / U - g["adv"] }
      assert_operator steps.min, :>, 0, "#{where}: tracked out, never in"
      steps.each { |step| assert_in_delta steps.first, step, 1e-9, "#{where}: the same space between every pair, a space included" }
    end
  end

  def test_the_tagline_forms_name_is_the_one_line_name
    TAGLINE_RATIOS.each_key do |brand, text|
      mine = stacked(brand).layout(text:, form: :tagline).letters.reject { |letter| letter[:word] == 2 }
      navbar = Navbar.new(brand).layout(rule: 4, text:)
      scale = 3 * U / navbar.cap
      assert_equal navbar.letters.map { |l| [l[:d], l[:word]] }, mine.map { |l| [l[:d], l[:word]] }, "#{brand} #{text}"
      mine.zip(navbar.letters).each do |letter, theirs|
        assert_in_delta (theirs[:x] - navbar.name_left) * scale, letter[:x], 1e-6, "#{brand} #{text}: both words, the word gap and tracking"
      end
    end
  end

  def test_the_tagline_is_quiet_in_light_and_dark_and_the_watermarks_one_fill
    { "studio" => ["#1A1535", "#FFFFFF"], "industries" => ["#41464D", "#D3D6DA"], "welding" => ["#2D5E8E", "#FFFFFF"] }.each do |brand, (light, dark)|
      line = ->(tone) { doc(stacked(brand).svg(form: :tagline, tone:, text: :first)).css("path[transform]").to_a.last(TAGLINES.fetch(brand).delete(" ").size) }
      assert_equal [light], line.(:light).map { |p| p["fill"] }.uniq, brand
      assert_equal [dark], line.(:dark).map { |p| p["fill"] }.uniq, brand
      assert_equal ["#FFFFFF"], line.(:watermark).map { |p| p["fill"] }.uniq, brand
      assert_equal ["nonzero"], line.(:light).map { |p| p["fill-rule"] }.uniq, "#{brand}: font outlines"
    end
    names = doc(stacked("welding").svg(form: :tagline)).css("path[transform]").to_a.first(17)
    assert_equal ["evenodd"], names.map { |p| p["fill-rule"] }.uniq, "welding's own lettering keeps its fill rule"
    assert_equal 1, stacked("studio").svg(form: :tagline, tone: :watermark).scan("opacity").size, "one translucent group"
  end

  def test_the_tagline_form_draws_only_paths_in_its_own_box
    TAGLINE_RATIOS.each_key do |brand, text|
      box = stacked(brand).layout(text:, form: :tagline)
      xml = doc(stacked(brand).svg(text:, form: :tagline))
      assert_equal %w[g path svg], xml.xpath("//*").map(&:name).uniq.sort
      assert_equal format("0 0 %.2f %.2f", box.width, box.height), xml.root["viewBox"]
    end
  end

  def test_a_tagline_too_wide_to_track_or_a_form_the_brand_lacks_is_refused
    message = refusal { Stacked.new("x", styles: style("studio", tagline: "BUILDING STRONG CONNECTIONS EVERY DAY")) }
    assert_match(/\Abrand x: the tagline "BUILDING STRONG CONNECTIONS EVERY DAY" cannot be tracked out to 60% of the name's width \(it is \d+% already\)/, message)
    assert_match(/brand x: the tagline "B" cannot be tracked out .* \(it has one letter\)/, refusal { Stacked.new("x", styles: style("studio", tagline: "B")) })
    assert_equal "brand turf: no stacked form :tagline (it has no tagline)", refusal { stacked("turf").svg(form: :tagline) }
    assert_equal "brand studio: no stacked form :one_line (it draws two_line and tagline)", refusal { stacked("studio").layout(form: :one_line) }
    assert_equal "brand studio: no stacked form \"tagline\" (it draws two_line and tagline)", refusal { stacked("studio").svg(form: "tagline") }
    assert_equal({ "studio" => %i[two_line tagline], "industries" => %i[two_line tagline], "turf" => %i[one_line], "welding" => %i[two_line tagline] },
                 Navbar.brands.to_h { |brand| [brand, stacked(brand).forms] })
    assert_equal stacked("studio").svg, stacked("studio").svg(form: :two_line), "a brand's own form is the default"
  end
end
