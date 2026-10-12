# frozen_string_literal: true

require "test_helper"

# [unit] THE KIT COMPARE (task logo-compare-and-original-edits): two brands' kits side by side. The pairing a Compare
# button opens on, each side's kit default (saved choice and kit icon, else the brand's style), the page's controls
# overriding it, the notes a side gives when it cannot take a control, and the one scale both sides are drawn at.
class LogoComparisonTest < ActiveSupport::TestCase
  BY = "alex@test.com"
  TONES = Logos::NavbarLogo::BAKED

  def params(**given) = ActionController::Parameters.new(given)
  def compare(left = "welding", right = "welding_v2", **) = LogoComparison.new(left:, right:, tones: TONES, kits: BrandKit.by_brand([left, right]), **)

  test "a brand pairs with its other version, else the next brand, and the page opens on Commercial Welding v1 and v2" do
    brands = %w[studio industries turf welding welding_v2]
    assert_equal "welding_v2", LogoComparison.partner("welding", brands)
    assert_equal "welding", LogoComparison.partner("welding_v2", brands)
    assert_equal "industries", LogoComparison.partner("studio", brands)
    assert_equal "studio", LogoComparison.partner("welding_v2", %w[studio welding_v2]), "the next brand, wrapping round"
    assert_equal %w[welding welding_v2], LogoComparison.default_pair(brands)
    assert_equal %w[studio industries], LogoComparison.default_pair(%w[studio industries turf])
  end

  test "with nothing saved each side draws its brand's style, in its own colouring" do
    sides = compare(type: :navbar).sides
    assert_equal %w[welding welding_v2], sides.map(&:brand)
    sides.each do |side|
      refute side.saved
      assert_empty side.changed
      assert_equal TONES, side.variants.keys
      variant = side.variant
      assert_equal [4, :second, :original], [variant.rule, variant.text, variant.colouring]
      assert_equal BrandKit.new(brand: side.brand).variant(:navbar).svg, variant.svg, "the same logo the table shows"
    end
  end

  test "each side draws its saved choice and kit icon, as its brand page opens on them" do
    BrandKit.for("welding_v2").save_choice(:stacked, params(form: "tagline", text: "second", colouring: "original", first_colour: "D7602E"), by: BY)
    BrandKit.for("welding_v2").save_choice(:icon, params(colouring: "alt", icon_colour: "D7602E"), by: BY)
    left, right = compare(type: :stacked).sides
    refute left.saved
    assert right.saved
    variant = right.variant
    assert_equal [:tagline, :second, :original, :alt], [variant.form, variant.text, variant.colouring, variant.icon_colouring]
    assert_equal({ icon: { colour: "#D7602E" }, first: { colour: "#D7602E" } }, variant.edits)
    assert_equal BrandKit.for("welding_v2").variant(:stacked).svg, variant.svg, "the kit default, exactly as saved"
    assert_equal :two_line, left.variant.form
  end

  test "the page's controls override each side's kit default and the side says which" do
    BrandKit.for("welding").save_choice(:navbar, params(rule: "4", text: "first", colouring: "alt"), by: BY)
    left, right = compare(type: :navbar, rule: 3, colouring: :original).sides
    assert_equal [3, :first, :original], [left.variant.rule, left.variant.text, left.variant.colouring]
    assert_equal %i[rule colouring], left.changed
    assert_equal %i[rule], right.changed, "Original is its own colouring already"
  end

  test "a control a side cannot take leaves it on its own, with a note" do
    left, right = compare("turf", "welding", type: :stacked, form: :tagline).sides
    assert_equal :one_line, left.variant.form
    assert_equal ["Turf Monster has no with tagline form, so it shows its own."], left.notes
    assert_equal :tagline, right.variant.form
    assert_equal %i[two_line one_line tagline], compare("turf", "welding", type: :stacked).forms, "every form either side draws"

    studio, = compare("studio", "welding", type: :navbar, colouring: :original).sides
    assert_equal :alt, studio.variant.colouring
    assert_match(/solid colour, so it has no Original/, studio.notes.first)
  end

  test "the grid draws construction guides on Navbar and Stacked, never on the icon" do
    assert compare(type: :navbar, grid: true).sides.all? { |side| side.variant.guides }
    assert compare(type: :stacked, grid: true).sides.all? { |side| side.variant.guides }
    refute compare(type: :icon, grid: true).grid
  end

  test "both sides are drawn at one scale: each width a share of the wider drawing's" do
    navbar = compare(type: :navbar, grid: true)
    shares = navbar.widths(:light)
    assert_in_delta 1.0, shares.max
    left, right = navbar.sides.map { |side| side.variant.svg[/viewBox="([^"]+)"/, 1].split.map(&:to_f) }
    assert_equal left[3], right[3], "every Navbar guide drawing is the same height in design units"
    assert_in_delta left[2] / right[2], shares[0] / shares[1], 1e-9
    assert_nil compare(type: :icon).widths(:light), "icons share no unit, so each fits its frame"
  end

  test "watermark sides carry the one watermark version" do
    comparison = LogoComparison.new(left: "welding", right: "welding_v2", type: :navbar, tones: [:watermark])
    assert_equal [[:watermark]], comparison.sides.map { |side| side.variants.keys }.uniq
  end
end
