# frozen_string_literal: true

# [unit] Logo COLOURINGS (task logo-original-and-alt): every logo type draws Original (the brand's own art, from the
# style's `original:`) or Alt (the style's `tones`, exactly as drawn before). A brand with no original draws Alt only;
# the watermark is one colour, so colouring does not apply to it. The word edits apply in either colouring, the icon's
# colour edit to an Alt icon only (task logo-compare-and-original-edits).

require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"
require_relative "../../lib/logos/variant"

class LogosColouringTest < Minitest::Test
  Navbar = Logos::NavbarLogo
  Stacked = Logos::StackedLogo
  Variant = Logos::Variant

  # Studio's style with an original: a deep violet icon and violet name on light, white on dark.
  ORIGINAL = { "light" => { "text" => "#635BB2", "icon" => { "primary" => "#635BB2" } },
               "dark" => { "text" => "#EEECFF", "quiet" => "#8E82FE", "icon" => { "primary" => "#EEECFF" } } }.freeze

  def styles(original = ORIGINAL, **changes) = { "duo" => Navbar.styles.fetch("studio").merge("original" => original).merge(changes.transform_keys(&:to_s)) }
  def duo(klass = Navbar, **) = klass.new("duo", styles: styles(**))
  def refusal(&) = assert_raises(Navbar::Error, &).message

  def test_a_brand_with_no_original_draws_alt_only
    studio = Navbar.new("studio")
    refute studio.original?
    assert_equal %i[alt], studio.colourings
    assert_equal studio.svg(rule: 4), studio.svg(rule: 4, colouring: :alt)
    assert_match(/brand studio: it has no original colouring \(its logo is solid colour\), so only alt/, refusal { studio.svg(colouring: :original) })
    assert_match(/no original colouring/, refusal { studio.icon_svg(colouring: :original) })
    assert_match(/no original colouring/, refusal { Stacked.new("studio").svg(colouring: :original) })
    assert_match(/unknown colouring :sepia: expected one of original, alt/, refusal { studio.svg(colouring: :sepia) })
  end

  def test_alt_is_exactly_what_the_logo_drew_before
    logo = duo
    assert_equal %i[original alt], logo.colourings
    Navbar::TONES.each do |tone|
      assert_equal Navbar.new("studio").svg(rule: 4, text: :first, tone:), logo.svg(rule: 4, text: :first, tone:, colouring: :alt), tone.to_s
      assert_equal Navbar.new("studio").icon_svg(tone:), logo.icon_svg(tone:), tone.to_s
    end
  end

  def test_original_draws_the_originals_own_fills_per_tone
    logo = duo
    light = logo.svg(rule: 3, text: :homogeneous, tone: :light, colouring: :original)
    dark = logo.svg(rule: 3, text: :second, tone: :dark, colouring: :original)
    assert_equal %w[#635BB2], light.scan(/fill="([^"]+)"/).flatten.uniq
    assert_equal %w[#EEECFF #8E82FE], dark.scan(/fill="([^"]+)"/).flatten.uniq, "icon and the leading word in text, the quiet word in quiet"
    refute_includes light, "#1A1535", "no Alt fill in an original"
    assert_equal logo.layout(rule: 3), logo.layout(rule: 3, colouring: :original), "the same icon, so the same geometry"
    assert_equal %w[#635BB2], logo.icon_svg(colouring: :original).scan(/fill="([^"]+)"/).flatten.uniq
    stacked = duo(Stacked)
    assert_equal %w[#EEECFF #8E82FE], stacked.svg(form: :tagline, tone: :dark, colouring: :original).scan(/fill="([^"]+)"/).flatten.uniq,
                 "the tagline takes the original's quiet"
  end

  def test_the_watermark_is_one_colour_whatever_the_colouring
    logo = duo
    assert_equal logo.svg(tone: :watermark), logo.svg(tone: :watermark, colouring: :original)
    assert_equal logo.icon_svg(tone: :watermark), logo.icon_svg(tone: :watermark, colouring: :original)
  end

  # Task logo-compare-and-original-edits: Alex coloured welding_v2's words in Alt only because Original refused them,
  # and Alt swapped the helmet for its single-colour version. The words now take their edits in Original too, and the
  # icon stays the original art.
  def test_word_edits_apply_in_original_and_leave_the_icon_as_the_brands_art
    edits = { first: { colour: "#8E82FE" } }
    assert_includes duo.svg(edits:), "#8E82FE"
    plain = duo.svg(rule: 4, text: :homogeneous, colouring: :original)
    edited = duo.svg(rule: 4, text: :homogeneous, colouring: :original, edits:)
    refute_equal plain, edited
    assert_includes edited, 'fill="#8E82FE"', "the first word takes the picked colour"
    assert_equal plain[%r{<path[^>]*/>}], edited[%r{<path[^>]*/>}], "the icon's first layer is drawn as the original drew it"
    assert_includes duo(Stacked).svg(edits:, colouring: :original), 'fill="#8E82FE"'
  end

  def test_an_original_icon_still_refuses_its_colour_edit
    assert_match(/an original icon is the brand's own art, so the icon's colour edit applies to an alt icon only/,
                 refusal { duo.svg(edits: { icon: { colour: "#8E82FE" } }, colouring: :original) })
  end

  def test_the_guide_ghosts_stay_the_alt_text_colour
    guided = duo.svg(rule: 3, guides: true, colouring: :original)
    ghosts = guided[%r{<g class="guide-ghosts".*?</g>}]
    assert_equal %w[#1A1535], ghosts.scan(/fill="([^"]+)"/).flatten.uniq, "a ghost is a solid ruler in the logo's Alt text colour"
  end

  def test_an_original_that_is_not_whole_is_refused_when_the_brand_loads
    assert_match(/original must be a map of light and dark/, refusal { duo(original: ORIGINAL.slice("light")) })
    assert_match(/original must be a map of light and dark/, refusal { duo(original: "#000000") })
    assert_match(/original light must be a map of icon_key, text, quiet, accent, icon with a text and an icon/,
                 refusal { duo(original: ORIGINAL.merge("light" => { "text" => "#000000" })) })
    assert_match(/original dark must be a map/, refusal { duo(original: ORIGINAL.merge("dark" => ORIGINAL["dark"].merge("glow" => "#FFFFFF"))) })
    assert_match(/original light has no fill for icon layer "primary"/,
                 refusal { duo(original: ORIGINAL.merge("light" => { "text" => "#000000", "icon" => { "edge" => "#000000" } })) })
    assert_match(/no icon "anvil"/, refusal { duo(original: ORIGINAL.merge("dark" => ORIGINAL["dark"].merge("icon_key" => "anvil"))) })
    [%(#000"/><script>), "#000000\n", "red", "url(#steel)\n", "url(#__LOGO_DEF__steel)", "url(#Steel)"].each do |fill|
      bad = ORIGINAL.merge("light" => { "text" => fill, "icon" => { "primary" => "#000000" } })
      assert_match(/is not a #hex colour/, refusal { duo(original: bad) }, fill.inspect)
      bad_icon = ORIGINAL.merge("light" => { "text" => "#000000", "icon" => { "primary" => fill } })
      assert_match(/is not a #hex colour/, refusal { duo(original: bad_icon) }, fill.inspect)
    end
    # A url names a gradient only when the original's own icon declares it (logos_gradients_test.rb has the rest).
    assert_match(/original light's url\(#steel\) names no gradient in icon studio's defs/,
                 refusal { duo(original: ORIGINAL.merge("light" => { "text" => "url(#steel)", "icon" => { "primary" => "#000000" } })) })
    colour = { "highlight" => "colour", "accent" => nil }
    assert_match(/original light needs an accent, because one word leads by colour/,
                 refusal { Navbar.new("duo", styles: { "duo" => styles.fetch("duo").merge(colour).merge("tones" => { "light" => { "text" => "#000000", "accent" => "#635BB2", "icon" => { "primary" => "#000000" } }, "dark" => { "text" => "#FFFFFF", "accent" => "#635BB2", "icon" => { "primary" => "#FFFFFF" } } }) }) })
  end

  def test_the_variant_reads_names_and_files_the_colouring
    logo = duo
    original = Variant.parse(logo, { rule: "4", text: "first", tone: "dark", colouring: "original" })
    assert_equal :original, original.colouring
    assert_equal logo.svg(rule: 4, text: :first, tone: :dark, colouring: :original), original.svg
    assert_equal "duo-navbar-rule4-first-dark-original.svg", original.filename
    assert_equal({ rule: 4, text: :first, tone: :dark, colouring: :original, guides: 0 }, original.params)
    assert_match(/, dark, original colouring\z/, original.label)

    alt = Variant.parse(logo, { rule: "4", text: "first", tone: "dark" })
    assert_equal :alt, alt.colouring, "an SVG route draws Alt unless asked"
    assert_equal "duo-navbar-rule4-first-dark.svg", alt.filename, "an Alt file is named as before"
    assert_equal({ rule: 4, text: :first, tone: :dark, guides: 0 }, alt.params, "an Alt URL is as before")
    assert_match(/, dark\z/, alt.label, "Alt is the default, named as before")

    icon = Variant.parse(logo, { tone: "light", colouring: "original" }, type: :icon)
    assert_equal "duo-icon-light-original.svg", icon.filename
    assert_equal logo.icon_svg(colouring: :original), icon.svg
    stacked = Variant.parse(duo(Stacked), { form: "tagline", colouring: "original" }, type: :stacked)
    assert_equal "duo-stacked-tagline-homogeneous-light-original.svg", stacked.filename
  end

  def test_the_variant_keeps_word_edits_in_either_colouring_and_drops_an_original_icons
    edited = { first_colour: "8E82FE" }
    assert_equal({ first: { colour: "#8E82FE" } }, Variant.parse(duo, edited).edits)
    original = Variant.parse(duo, edited.merge(colouring: "original", icon_colour: "635BB2"))
    assert_equal({ first: { colour: "#8E82FE" } }, original.edits, "the words' edit is shown; the original icon's colour is not")
    assert_includes original.filename, "custom"
    assert_includes original.svg, 'fill="#8E82FE"'
  end

  def test_a_watermark_variant_is_alt_and_says_no_colouring
    mark = Variant.parse(duo, { tone: "watermark", colouring: "original" })
    assert_equal :alt, mark.colouring
    assert_equal "duo-navbar-rule3-homogeneous-watermark.svg", mark.filename
    refute_match(/colouring/, mark.label)
  end

  def test_an_unknown_or_unavailable_colouring_is_refused
    assert_match(/unknown colouring "sepia": expected one of original, alt/, refusal { Variant.parse(duo, { colouring: "sepia" }) })
    assert_match(/unknown colouring ""/, refusal { Variant.colouring("") })
    assert_nil Variant.colouring(nil)
    studio = Navbar.new("studio")
    assert_match(/brand studio: it has no original colouring/, refusal { Variant.parse(studio, { colouring: "original" }) })
    assert_equal :alt, Variant.parse(studio, { colouring: "alt" }).colouring
    refute_match(/colouring/, Variant.parse(studio, {}).label, "a brand with Alt only does not name it")
  end
end
