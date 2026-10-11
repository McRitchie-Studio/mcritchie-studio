# frozen_string_literal: true

# [unit] Gradient fills in icon data (task logo-original-and-alt): an ORIGINAL's fill may be url(#<id>) only when its
# own icon data declares that gradient in a validated `defs` entry (a linearGradient with numeric coordinates and #hex
# stops). The drawing writes it namespaced by the icon and by a digest of the drawing, so two logos on one page never
# share an id. Every other fill stays a #hex, and an Alt drawing has no defs at all. The Industries Original is the
# case in the shipped data: the kit's steel gradient and ruler ticks.

require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"

class LogosGradientsTest < Minitest::Test
  Navbar = Logos::NavbarLogo
  Stacked = Logos::StackedLogo

  def industries = @industries ||= Navbar.new("industries")
  def refusal(&) = assert_raises(Navbar::Error, &).message
  def ids(svg) = svg.scan(/<linearGradient id="([^"]+)"/).flatten
  def refs(svg) = svg.scan(/url\(#([^)]+)\)/).flatten

  def test_the_industries_original_draws_the_kits_steel_gradient_and_ruler_ticks
    %i[light dark].each do |tone|
      svg = industries.icon_svg(tone:, colouring: :original)
      assert_equal ["industries_original_#{tone}"], ids(svg).map { |id| id[/\A[a-z_]+/] }, "#{tone}: one gradient, the icon's steel"
      assert_match(/\Aindustries_original_#{tone}-\h{8}-steel\z/, ids(svg).first)
      assert_equal ids(svg), refs(svg).uniq, "#{tone}: the icon fills with the gradient it declares"
      assert_equal 1, svg.scan(/<path d="M200\.8,374\.9 [^"]*" fill="none" stroke="#\h{6}" stroke-width="1\.6"\/>/).size, "#{tone}: the ruler ticks, stroked"
    end
    light = industries.icon_svg(colouring: :original)
    assert_includes light, %(<stop offset="0" stop-color="#59606A"/><stop offset="1" stop-color="#262A30"/>), "the kit's light steel"
    assert_includes industries.icon_svg(tone: :dark, colouring: :original), %(<stop offset="0" stop-color="#F4F5F7"/>), "the kit's dark steel"
  end

  def test_the_original_name_takes_the_wordmarks_gradient_in_letter_units
    svg = industries.svg(rule: 4, text: :first, colouring: :original)
    steel, name = ids(svg)
    assert_match(/-steel\z/, steel)
    assert_match(/-steel_name\z/, name)
    assert_includes svg, %(id="#{name}" gradientUnits="userSpaceOnUse" x1="0" y1="-1" x2="0" y2="0">), "cap top to baseline in every letter"
    letters = svg.scan(/<path transform="translate[^>]*fill="([^"]+)"/).flatten
    assert_equal ["url(##{name})", "#41464D"], letters.uniq, "the leading word in steel, the other in the kit's gunmetal"
    homogeneous = industries.svg(rule: 4, colouring: :original).scan(/<path transform="translate[^>]*fill="([^"]+)"/).flatten.uniq
    assert_equal 1, homogeneous.size
    assert_match(/\Aurl\(#industries_original_light-\h{8}-steel_name\)\z/, homogeneous.first, "both words in steel when alike")
  end

  def test_ids_are_namespaced_per_output_and_the_same_output_is_the_same_bytes
    drawings = [industries.icon_svg(colouring: :original), industries.svg(rule: 3, colouring: :original),
                industries.svg(rule: 4, colouring: :original), industries.svg(rule: 4, tone: :dark, colouring: :original),
                Stacked.new("industries").svg(form: :tagline, colouring: :original), industries.svg(rule: 4, guides: true, colouring: :original)]
    all = drawings.flat_map { |svg| ids(svg) }
    assert_equal all.uniq, all, "no two logos on a page share a gradient id"
    drawings.each { |svg| assert_empty refs(svg) - ids(svg), "every url names a gradient in its own drawing" }
    assert_equal industries.svg(rule: 4, colouring: :original), Navbar.new("industries").svg(rule: 4, colouring: :original), "deterministic"
    refute_includes drawings.join, Navbar::DEF_TOKEN, "no placeholder is left in markup"
  end

  def test_alt_draws_no_gradient_and_no_defs
    assert_equal [], ids(industries.svg(rule: 4) + industries.icon_svg(tone: :dark) + industries.svg(tone: :watermark))
    refute_includes industries.svg(rule: 4), "<defs>"
  end

  # The studio style, with an original whose icon is the test's own (`defs` and layers below).
  def gradient_icon(defs: [{ "id" => "glow", "units" => "userSpaceOnUse", "x1" => 0, "y1" => 0, "x2" => 0, "y2" => 10,
                             "stops" => [{ "offset" => 0, "colour" => "#000000" }, { "offset" => 1, "colour" => "#FFFFFF" }] }],
                    layers: [{ "role" => "primary", "fill_rule" => "nonzero", "d" => "M0,0L10,0L10,10Z" }])
    { "w" => 10, "h" => 10, "defs" => defs, "layers" => layers }.compact
  end

  def logo(icon = gradient_icon, key: "glowing", fill: "url(#glow)", text: "#000000", tones: nil)
    style = Navbar.styles.fetch("studio").merge("original" => { "light" => { "icon_key" => key, "text" => text, "icon" => { "primary" => fill } },
                                                                "dark" => { "icon_key" => key, "text" => text, "icon" => { "primary" => fill } } })
    style = style.merge("tones" => tones) if tones
    Navbar.new("x", styles: { "x" => style }, icons: Navbar.icons.merge(key => icon))
  end

  def test_a_declared_gradient_is_drawn
    svg = logo.icon_svg(colouring: :original)
    assert_match(%r{<defs><linearGradient id="glowing-\h{8}-glow" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="10">}, svg)
    assert_includes logo(text: "url(#glow)").svg(colouring: :original), 'fill="url(#glowing-', "the name may take it too"
  end

  def test_a_url_to_a_gradient_the_icon_does_not_declare_is_refused
    assert_match(/original light's url\(#steel\) names no gradient in icon glowing's defs/, refusal { logo(fill: "url(#steel)") })
    assert_match(/names no gradient in icon glowing's defs/, refusal { logo(text: "url(#ember)") })
    no_defs = gradient_icon(defs: nil)
    assert_match(/url\(#glow\) names no gradient/, refusal { logo(no_defs) })
    # Alt fills stay #hex only, gradient or none; and no style value can pose as a drawn reference.
    alt = { "light" => { "text" => "#000000", "icon" => { "primary" => "url(#glow)" } }, "dark" => { "text" => "#FFFFFF", "icon" => { "primary" => "#FFFFFF" } } }
    assert_match(/"url\(#glow\)" is not a #hex colour/, refusal { logo(tones: alt).svg })
    ["url(#__LOGO_DEF__glow)", "url(#glow)\n", "url(#glow) red", "url(#Glow)", "url('#glow')", "url(#glow\")"].each do |fill|
      assert_match(/is not a #hex colour/, refusal { logo(fill:) }, fill.inspect)
    end
  end

  def test_a_gradient_that_is_not_plain_data_is_refused
    good = gradient_icon.fetch("defs").first
    bad = {
      "must be a list of linear gradients" => ["glow", []],
      "a gradient is a map of id, units, x1, y1, x2, y2, stops" => [{}, good.except("x2"), good.merge("href" => "#x")],
      "gradient id .* must be lower-case letters, digits and _" => [good.merge("id" => "Glow"), good.merge("id" => "glow\"><script>"), good.merge("id" => 7)],
      "units must be userSpaceOnUse or objectBoundingBox" => [good.merge("units" => "strokeWidth")],
      "x1 must be a number" => [good.merge("x1" => "0"), good.merge("x1" => Float::NAN), good.merge("x1" => Float::INFINITY)],
      "needs two or more stops" => [good.merge("stops" => [good["stops"].first]), good.merge("stops" => "#000")],
      "has a stop that is not" => [good.merge("stops" => [{ "offset" => 0, "colour" => "red" }, good["stops"].last]),
                                   good.merge("stops" => [{ "offset" => 2, "colour" => "#000000" }, good["stops"].last]),
                                   good.merge("stops" => [{ "offset" => 0, "colour" => "#000000\n" }, good["stops"].last]),
                                   good.merge("stops" => [{ "offset" => 0, "colour" => "#000000", "opacity" => 0.5 }, good["stops"].last])],
      "two gradients share an id" => [[good, good]]
    }
    bad.each do |message, values|
      values.each do |value|
        defs = value.is_a?(Array) || !value.is_a?(Hash) ? value : [value]
        assert_match(/#{message}/, refusal { logo(gradient_icon(defs:)) }, value.inspect[0, 80])
      end
    end
    assert_match(/icon key "glow-ing" cannot name a gradient/, refusal { logo(key: "glow-ing") })
  end

  def test_a_stroked_layer_needs_a_width_and_a_filled_one_takes_none
    stroked = ->(layer) { gradient_icon(layers: [{ "role" => "primary", "fill_rule" => "nonzero", "d" => "M0,0L10,10" }.merge(layer)]) }
    assert_includes logo(stroked.({ "paint" => "stroke", "stroke_width" => 2 }), fill: "#000000").icon_svg(colouring: :original),
                    %(fill="none" stroke="#000000" stroke-width="2"/>)
    assert_match(/needs a stroke_width greater than 0, got nil/, refusal { logo(stroked.({ "paint" => "stroke" })) })
    [0, -1, "2", Float::NAN].each do |width|
      assert_match(/needs a stroke_width greater than 0/, refusal { logo(stroked.({ "paint" => "stroke", "stroke_width" => width })) }, width.inspect)
    end
    assert_match(/is filled, so it takes no stroke_width/, refusal { logo(stroked.({ "stroke_width" => 2 })) })
    assert_match(/has paint "glow": expected fill or stroke/, refusal { logo(stroked.({ "paint" => "glow" })) })
  end
end
