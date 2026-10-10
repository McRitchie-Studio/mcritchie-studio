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

  # SHA-256 over every stacked logo WITHOUT guides (4 brands x 3 texts x 3 tones, "<key>\n<svg>" each) and every icon
  # (4 brands x 3 tones), taken on `accepted` at 4368b9183 before the tagline form and the ghost grids (task
  # stacked-tagline-and-ghost-grid): a new form and new guide drawings may not move a shipped logo by a byte.
  STACKED_DIGEST = "6b40237f0a2b759fe9d3d67f5d3af417e982c18c99d54d73859bd7974cdd8a6d"
  ICON_DIGEST = "4196eaad2022f4866444301ed821104d48a6f06f793fbd95b90e7fe4c86d2c58"
  # Width / height of the tagline form, measured (task stacked-tagline-and-ghost-grid). Each equals 3n / (1.8n + 8), n the
  # name's ink width in cap heights: the tagline form is as tall as the two-line form (icon 0.6W, then 2u, 3u, 2u, 1u).
  TAGLINE_RATIOS = {
    ["studio", :homogeneous] => 1.2708, ["studio", :first] => 1.2645, ["studio", :second] => 1.2609,
    ["industries", :homogeneous] => 1.3270, ["industries", :first] => 1.3214, ["industries", :second] => 1.3215,
    ["welding", :homogeneous] => 1.2838, ["welding", :first] => 1.2838, ["welding", :second] => 1.2838
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
      assert_in_delta (theirs[:x] - navbar.name_left) * scale, mine[:x], 1e-6, "the brand's tracking and word space, at this size"
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
    xml.css("g.guide-ghosts path").select { |p| p["transform"][/translate\(([-\d.]+),/, 1].to_f > box.width }
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

  def test_the_ruler_copies_the_small_line_the_tagline_or_a_third_size_name
    box = stacked("turf").layout(text: :second)
    assert_in_delta box.width / (3 * U), box.ruler_width, 1e-9, "one line: the name at a third of its size"
    navbar = Navbar.new("turf").layout(rule: 4, text: :second)
    assert_equal navbar.letters.map { |l| l[:d] }, box.ruler.map { |l| l[:d] }
    tagline = stacked("welding").layout(form: :tagline)
    assert_equal "BUILDING STRONG CONNECTIONS".chars.map { |char| glyph(char, 500)["d"] }, tagline.ruler.map { |l| l[:d] }
    assert_equal ["nonzero"], tagline.ruler.map { |l| l[:fill_rule] }.uniq
    two = stacked("industries").layout(text: :first)
    assert_equal "INDUSTRIES".chars.map { |char| glyph(char, 300)["d"] }, two.ruler.map { |l| l[:d] }, "the small word in its own weight, untracked"
    assert_in_delta "INDUSTRIES".chars.map { |c| glyph(c, 300) }.then { |g| g[0...-1].sum { |x| x["adv"] } + g.last["r"] - g.first["l"] }, two.ruler_width, 1e-9
  end

  def test_the_small_line_runs_down_the_icons_axis_as_tall_as_the_icon
    guided.each do |brand, form, tone|
      box = stacked(brand).layout(form:, tone:, text: :first)
      xml = doc(stacked(brand).svg(form:, tone:, text: :first, guides: true)).remove_namespaces!
      axis = xml.css("g.guide-ghosts path").reject { |p| p["transform"][/translate\(([-\d.]+),/, 1].to_f > box.width }
      where = "#{brand} #{form} #{tone}"
      assert_equal box.ruler.reject { |l| l[:d].empty? }.map { |l| l[:d] }, axis.map { |p| p["d"] }, "#{where}: the small line's letters, in order"
      baselines = axis.map { |p| p["transform"][/,([-\d.]+)\)/, 1].to_f }
      cap = axis.first["transform"][/scale\(([\d.]+)\)/, 1].to_f
      assert_operator cap, :<=, U, where
      assert_equal baselines.sort, baselines, "#{where}: one under another"
      assert_in_delta cap, baselines.first, 0.01, "#{where}: the first letter's capitals start at the icon's top"
      assert_in_delta box.icon_height, baselines.last, 0.01, "#{where}: the last one sits on the icon's foot"
      assert_operator baselines.each_cons(2).map { |a, b| b - a }.min, :>=, cap / Stacked::AXIS_FILL - 0.02, "#{where}: no two letters touch"
      centres = axis.zip(box.ruler.reject { |l| l[:d].empty? }).map { |p, l| p["transform"][/translate\(([-\d.]+),/, 1].to_f + (l[:l] + l[:r]) / 2 * cap }
      centres.each { |x| assert_in_delta box.width / 2, x, 0.01, "#{where}: centred on the axis" }

      lines = xml.css("g.guide-lines line")
      horizontal, vertical = lines.partition { |l| l["y1"] == l["y2"] }
      assert_equal box.edges.map { |y| format("%.2f", y) }, horizontal.map { |l| l["y1"] }, "#{where}: a line at each band boundary only"
      assert_equal [[format("%.2f", box.width / 2), "-20.00", format("%.2f", box.height + 20)]], vertical.map { |l| [l["x1"], l["y1"], l["y2"]] }, where
      right = horizontal.map { |l| l["x2"].to_f }.uniq
      assert_equal 1, right.size
      assert_operator right.first, :>, ruler_rows(xml, box).values.flatten.map { |p| p["transform"][/translate\(([-\d.]+),/, 1].to_f }.max, "#{where}: across the ruler"
      top = xml.css("g.guide-lines text").last
      assert_equal ["1", format("%.2f", box.width / 2 + 10), "-10.00"], [top.text, top["x"], top["y"]], "#{where}: a 1 at the icon's top"
    end
  end

  def test_the_guide_drawing_reaches_past_the_ruler
    box = stacked("industries").layout(text: :first)
    xml = doc(stacked("industries").svg(text: :first, guides: true))
    right = Stacked::RULER_X + box.ruler_width * U + 40
    assert_equal format("-40 -40 %.2f %.2f", box.width + 40 + right, box.height + 80), xml.root["viewBox"]
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

  def test_every_stacked_logo_and_icon_without_guides_is_unchanged_to_the_byte
    all = Navbar.brands.flat_map do |brand|
      Navbar::TEXTS.product(Navbar::TONES).map { |text, tone| "#{brand}-stacked-#{text}-#{tone}\n#{stacked(brand).svg(text:, tone:)}" }
    end
    assert_equal 36, all.size
    assert_equal STACKED_DIGEST, Digest::SHA256.hexdigest(all.join)
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
        assert_in_delta (theirs[:x] - navbar.name_left) * scale, letter[:x], 1e-6, "#{brand} #{text}: both words, the word space and tracking"
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
