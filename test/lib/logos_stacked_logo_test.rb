# frozen_string_literal: true

# [unit] Logos::StackedLogo (task logo-tabs-icon-and-stacked): the 3-2-1
# geometry of the two-line and the one-line form, the computed tracking, the
# text versions and tones it shares with the Navbar Logo, the guide drawing,
# the vector-only output, and the refusals.

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

  def test_guides_draw_each_boundary_each_bands_size_and_the_small_word_on_its_side
    logo = stacked("industries")
    box = logo.layout(text: :first)
    xml = doc(logo.svg(text: :first, guides: true)).remove_namespaces!
    pad = Stacked::GUIDE_PAD
    assert_equal format("-60 -40 %.2f %.2f", box.width + pad[:left] + pad[:right], box.height + pad[:top] + pad[:bottom]), xml.root["viewBox"]

    lines = xml.css("line")
    assert_equal box.edges.map { |y| format("%.2f", y) }, lines.map { |l| l["y1"] }
    lines.each { |l| assert_equal [l["y1"], "-20.00", format("%.2f", box.width + 20)], [l["y2"], l["x1"], l["x2"]] }
    labels = xml.css("text")
    assert_equal %w[2u 3u 2u 1u], labels.map(&:text)
    assert_equal ["30"], labels.map { |t| t["font-size"] }.uniq
    labels.zip(box.edges.drop(1).each_cons(2)).each do |label, (top, bottom)|
      assert_in_delta (top + bottom) / 2, label["y"].to_f - 10.5, 0.01, "#{label.text} sits in the middle of its band"
      assert_operator label["x"].to_f, :>, box.width
    end

    turned = xml.css("g").select { |g| g["transform"].to_s.include?("rotate(-90)") }
    assert_equal [format("translate(%.2f,%.2f) rotate(-90)", box.icon_left - 60, box.icon_height)], turned.map { |g| g["transform"] }
    small = turned.first.css("path")
    glyphs = "INDUSTRIES".chars.map { |char| glyph(char, 300) }
    assert_equal glyphs.map { |g| g["d"] }, small.map { |p| p["d"] }, "the small word again, turned"
    assert_equal [Stacked::GUIDE], small.map { |p| p["fill"] }.uniq
    xs = small.map { |p| p["transform"][/translate\(([-\d.]+),0\.00\)/, 1].to_f }
    assert_in_delta 0, xs.first + glyphs.first["l"] * U, 0.01, "its ink starts at the icon's bottom edge"
    assert_in_delta box.icon_height, xs.last + glyphs.last["r"] * U, 0.01, "and ends at the icon's top: the icon is as tall as the word is wide"
  end

  def test_the_one_line_guides_stop_at_3u_and_bracket_the_icons_height
    box = stacked("turf").layout
    xml = doc(stacked("turf").svg(guides: true)).remove_namespaces!
    horizontal, vertical = xml.css("line").partition { |l| l["y1"] == l["y2"] }
    assert_equal box.edges.map { |y| format("%.2f", y) }, horizontal.map { |l| l["y1"] }
    assert_equal [["0.00", format("%.2f", box.icon_height)]], vertical.map { |l| [l["y1"], l["y2"]] }
    assert_equal ["2u", "3u", "60% of the name's width"], xml.css("text").map(&:text)
    assert_equal ["middle"], xml.css("text[transform*='rotate(-90)']").map { |t| t["text-anchor"] }
    assert_empty xml.css("g").select { |g| g["transform"].to_s.include?("rotate") }, "there is no small word to turn"
  end

  def test_a_watermarks_guides_are_drawn_at_full_strength_outside_the_group
    xml = doc(stacked("studio").svg(tone: :watermark, guides: true)).remove_namespaces!
    assert_equal "0.6", xml.root.element_children.first["opacity"]
    assert_empty xml.css("g[opacity] line, g[opacity] text, g[opacity] g[transform*='rotate']")
    assert_equal 6, xml.root.xpath("./line").size
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

    wide = JSON.parse(JSON.generate(Navbar.icons)).tap { |icons| icons.fetch("studio")["w"] = 2000 }
    assert_match(/brand studio: the icon is too wide to stack \(2\.22 of the name's width at this height\)/, refusal { Stacked.new("studio", icons: wide) })
    refute_respond_to stacked("studio"), :examples
    assert_respond_to Navbar.new("studio"), :examples
  end

  def test_every_shipped_brand_stacks_in_the_form_its_style_names
    assert_equal({ "studio" => :two_line, "industries" => :two_line, "turf" => :one_line, "welding" => :two_line },
                 Navbar.brands.to_h { |brand| [brand, stacked(brand).form] })
  end
end
