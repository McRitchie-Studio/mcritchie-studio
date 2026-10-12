# frozen_string_literal: true

# [unit] The icon as an atomic unit: its own colouring and colour edit, the words in theirs.

require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"
require_relative "../../lib/logos/variant"

# THE ICON IS AN ATOMIC UNIT (task kit-icon-atomic-unit): a Navbar or Stacked Logo's icon may be drawn in a colouring
# of its own (`icon_colouring:`, the kit's icon) while `colouring:` governs the words. Left out, every drawing is the
# one it was (the byte pins in logos_brand_pins_test.rb and the per-type digests hold that).
class LogosIconAtomicUnitTest < Minitest::Test
  Navbar = Logos::NavbarLogo
  Stacked = Logos::StackedLogo
  Variant = Logos::Variant

  def refusal(&) = assert_raises(Navbar::Error, &).message
  def fills(svg) = svg.scan(/(?:fill|stroke)="([^"]+)"/).flatten
  def unfilled(svg) = svg.gsub(/ (?:fill|stroke)="[^"]+"/, "")
  # A drawing's letters (each carries its own transform), and its icon (everything before them).
  def letters(svg) = svg.scan(/<path transform="translate\([^"]+\) scale\([^"]+\)" d="[^"]*" fill="[^"]+"/)
  def icon_part(svg) = svg[0...svg.index('<path transform="translate(')]

  def test_an_icon_colouring_equal_to_the_words_draws_exactly_what_it_did
    %w[welding_v2 industries turf].each do |brand|
      navbar = Navbar.new(brand)
      stacked = Stacked.new(brand)
      %i[light dark].product(%i[original alt]) do |tone, colouring|
        assert_equal navbar.svg(rule: 4, tone:, colouring:), navbar.svg(rule: 4, tone:, colouring:, icon_colouring: colouring), "#{brand} #{tone} #{colouring}"
        assert_equal stacked.svg(tone:, colouring:, guides: true), stacked.svg(tone:, colouring:, guides: true, icon_colouring: colouring)
      end
    end
  end

  # Alex's case: Commercial Welding v2 with Alt words and the Original helmet. The icon is the Original's, the layout
  # is the Original's (it follows the icon's width), and the words take Alt's fills.
  def test_alt_words_with_the_original_icon_draw_the_original_helmet
    logo = Navbar.new("welding_v2")
    %i[light dark].each do |tone|
      mixed = logo.svg(rule: 3, text: :first, tone:, colouring: :alt, icon_colouring: :original)
      original = logo.svg(rule: 3, text: :first, tone:, colouring: :original)
      alt = logo.svg(rule: 3, text: :first, tone:, colouring: :alt)
      assert_equal icon_part(original), icon_part(mixed), "#{tone}: the original helmet"
      assert_equal unfilled(original), unfilled(mixed), "#{tone}: the original's geometry"
      assert_equal fills(letters(alt).join), fills(letters(mixed).join), "#{tone}: the words in Alt"
    end
    refute_equal logo.svg(rule: 3, text: :first, tone: :dark, colouring: :alt),
                 logo.svg(rule: 3, text: :first, tone: :dark, colouring: :alt, icon_colouring: :original), "the dark Alt helmet is the single-colour one"
  end

  def test_the_stacked_logo_takes_the_icon_the_same_way
    logo = Stacked.new("welding_v2")
    %i[two_line tagline].product(%i[light dark]) do |form, tone|
      mixed = logo.svg(form:, text: :first, tone:, colouring: :alt, icon_colouring: :original)
      original = logo.svg(form:, text: :first, tone:, colouring: :original)
      alt = logo.svg(form:, text: :first, tone:, colouring: :alt)
      assert_equal unfilled(original), unfilled(mixed), "#{form} #{tone}"
      assert_equal fills(letters(alt).join), fills(letters(mixed).join), "#{form} #{tone}: the words and tagline in Alt"
    end
  end

  # Industries' original names gradients its own icon declares: the icon's for an Original icon, the name's steel for
  # Original words. Either way the drawing declares them, and an Alt part stays #hex.
  def test_an_original_part_brings_its_gradients_whichever_part_it_is
    logo = Navbar.new("industries")
    icon_original = logo.svg(rule: 4, colouring: :alt, icon_colouring: :original)
    assert_includes icon_original, "<defs>"
    assert_match(/fill="url\(#industries_original_light-\h{8}-steel\)"/, icon_original)
    refute_match(/steel_name/, icon_original, "Alt words are #hex")

    words_original = logo.svg(rule: 4, colouring: :original, icon_colouring: :alt)
    assert_match(/fill="url\(#industries_original_light-\h{8}-steel_name\)"/, words_original)
    assert_equal icon_part(logo.svg(rule: 4, colouring: :alt)).sub(/\A<svg[^>]*>/, ""), icon_part(words_original).sub(/\A<svg[^>]*><defs>.*?<\/defs>/, "")
  end

  def test_each_parts_edits_follow_its_own_colouring
    logo = Navbar.new("welding_v2")
    icon = { icon: { colour: "#D7602E" } }
    words = { first: { colour: "#D7602E" } }
    assert_includes logo.svg(rule: 4, colouring: :original, icon_colouring: :alt, edits: icon), 'fill="#D7602E"', "an Alt icon takes its colour under Original words"
    assert_includes logo.svg(rule: 4, colouring: :alt, icon_colouring: :original, edits: words), 'fill="#D7602E"'
    assert_match(/an original icon is the brand's own art/, refusal { logo.svg(rule: 4, colouring: :alt, icon_colouring: :original, edits: icon) })
    # Task logo-compare-and-original-edits: Original words take their edits too.
    assert_includes logo.svg(rule: 4, colouring: :original, icon_colouring: :alt, edits: words), 'fill="#D7602E"'
  end

  def test_the_watermark_is_the_single_colour_icon_whatever_the_icon_colouring
    logo = Navbar.new("welding_v2")
    assert_equal logo.svg(rule: 4, tone: :watermark), logo.svg(rule: 4, tone: :watermark, icon_colouring: :original)
  end

  def test_a_brand_with_no_original_refuses_an_original_icon
    assert_match(/no original colouring/, refusal { Navbar.new("studio").svg(icon_colouring: :original) })
  end

  def test_the_icon_alone_takes_its_colour_edit_and_nothing_else
    logo = Navbar.new("studio")
    edited = logo.icon_svg(edits: { icon: { colour: "#635BB2" } })
    assert_includes edited, 'fill="#635BB2"'
    refute_equal logo.icon_svg, edited
    assert_match(/takes only the icon's colour edit/, refusal { logo.icon_svg(edits: { first: { colour: "#635BB2" } }) })
    assert_match(/applies to an alt icon only/, refusal { Navbar.new("welding_v2").icon_svg(colouring: :original, edits: { icon: { colour: "#D7602E" } }) })
  end

  def test_the_variant_names_and_routes_an_icon_of_its_own
    logo = Navbar.new("welding_v2")
    variant = Variant.new(logo, rule: 4, text: :second, colouring: :alt, icon_colouring: :original)
    assert_predicate variant, :own_icon?
    assert_equal({ rule: 4, text: :second, tone: :light, icon_colouring: :original, guides: 0 }, variant.params)
    assert_equal "welding_v2-navbar-rule4-second-light-icon-original.svg", variant.filename
    assert_includes variant.label, "original icon"
    assert_equal variant.svg, Variant.parse(logo, variant.params.transform_values(&:to_s)).svg, "the SVG route draws what the page shows"
    assert_equal logo.svg(rule: 4, text: :second, colouring: :alt, icon_colouring: :original), variant.svg

    same = Variant.new(logo, rule: 4, colouring: :original, icon_colouring: :original)
    refute_predicate same, :own_icon?
    refute_includes same.params.keys, :icon_colouring
    refute_includes same.filename, "icon-"
    refute_predicate Variant.new(logo, rule: 4, tone: :watermark, icon_colouring: :original), :own_icon?, "a watermark is one colour"
  end

  def test_the_variant_shows_an_icon_edit_only_on_an_alt_icon
    logo = Navbar.new("welding_v2")
    edits = { icon: { colour: "#D7602E" }, first: { colour: "#D7602E" } }
    assert_equal(edits, Variant.new(logo, colouring: :original, icon_colouring: :alt, edits:).edits, "an Alt icon and Original words both take theirs")
    assert_equal({ first: { colour: "#D7602E" } }, Variant.new(logo, colouring: :alt, icon_colouring: :original, edits:).edits)
    assert_equal({ first: { colour: "#D7602E" } }, Variant.new(logo, colouring: :original, edits:).edits, "Original words keep their edit")
    assert_empty Variant.new(logo, type: :icon, colouring: :original, edits:).edits
  end
end
