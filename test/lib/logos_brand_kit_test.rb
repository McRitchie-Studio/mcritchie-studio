# frozen_string_literal: true

# [unit] Logos::BrandKit (task brand-gallery-palette-and-theme): each brand's
# one named colour palette, read from config/logo_brands.yml and checked on
# load, so bad data fails before a page renders it.

require "minitest/autorun"
require_relative "../../lib/logos/brand_kit"

class LogosBrandKitTest < Minitest::Test
  BrandKit = Logos::BrandKit

  def palette(brand) = BrandKit.new(brand).palette.map { |swatch| [swatch.name, swatch.hex] }

  def style(**overrides)
    { "kit" => Logos::NavbarLogo.styles.fetch("studio").merge(overrides.transform_keys(&:to_s)) }
  end

  def refusal(**overrides) = assert_raises(Logos::NavbarLogo::Error) { BrandKit.new("kit", styles: style(**overrides)) }.message

  def test_studio_has_exactly_the_five_colours_alex_chose
    assert_equal [["Ink", "#1A1535"], ["Violet", "#8E82FE"], ["Deep Violet", "#635BB2"], ["Violet Mist", "#EEECFF"], ["White", "#FFFFFF"]],
                 palette("studio")
  end

  def test_industries_has_the_marketing_kits_eight_in_order
    assert_equal %w[#C8661F #E07B2E #262A30 #59606A #8C939C #D3D6DA #141516 #FFFFFF], palette("industries").map(&:last)
    assert_equal ["Forge Orange", "Ember Orange", "Charcoal Steel", "Gunmetal", "Brushed Steel", "Light Steel", "Shop Black", "White"],
                 palette("industries").map(&:first)
  end

  def test_turf_and_welding_have_their_full_palettes
    assert_equal [["Brand Green", "#4BAF50"], ["Forest", "#2E7D32"], ["Deep Green", "#1A550D"], ["Grass", "#5C972A"],
                  ["Cream", "#F0EBCF"], ["Ink", "#1A1535"], ["Violet", "#8E82FE"]], palette("turf")
    assert_equal [["Welding Blue", "#2D5E8E"], ["Spark Orange", "#D7602E"], ["Ember", "#F08A5A"], ["White", "#FFFFFF"]], palette("welding")
  end

  def test_every_brand_has_a_kit
    assert_equal Logos::NavbarLogo.brands, BrandKit.all.map(&:brand)
  end

  def test_a_palette_is_frozen
    assert_predicate BrandKit.new("studio").palette, :frozen?
  end

  def test_an_unknown_brand_is_refused
    assert_match(/unknown brand "nope"/, assert_raises(Logos::NavbarLogo::Error) { BrandKit.new("nope") }.message)
  end

  def test_a_missing_or_empty_palette_is_refused
    assert_match(/palette must be a list of at least one/, refusal(palette: nil))
    assert_match(/palette must be a list of at least one/, refusal(palette: []))
    assert_match(/palette must be a list of at least one/, refusal(palette: { "name" => "Ink", "hex" => "#000" }))
  end

  def test_a_colour_needs_exactly_a_name_and_a_hex
    assert_match(/map of name and hex/, refusal(palette: [{ "name" => "Ink" }]))
    assert_match(/map of name and hex/, refusal(palette: [{ "name" => "Ink", "hex" => "#000", "tone" => "dark" }]))
    assert_match(/map of name and hex/, refusal(palette: ["#000000"]))
  end

  # The hex guard is the library's own (Logos::NavbarLogo::HEX), anchors included: a hex goes into a style attribute.
  def test_a_hex_must_be_a_whole_hex_colour
    ["#000\"/><script>", "#000000\n", "\n#000000", "000000", "#12345", "#GGGGGG", "red", 0x123456, nil].each do |bad|
      assert_match(/is not a #hex colour/, refusal(palette: [{ "name" => "Ink", "hex" => bad }]), bad.inspect)
    end
    assert_equal "#abc", BrandKit.new("kit", styles: style(palette: [{ "name" => "Ink", "hex" => "#abc" }])).palette.first.hex
  end

  def test_a_name_must_be_plain_words
    ["", " Ink", "<b>Ink</b>", "Ink\"", "Ink\nViolet", nil, 7].each do |bad|
      assert_match(/palette colour name must be plain words/, refusal(palette: [{ "name" => bad, "hex" => "#000" }]), bad.inspect)
    end
  end
end

# [unit] The typeface hierarchy: at most three levels, each a role and a face the hub serves (or the brand's own
# traced lettering, which names no font), named "Montserrat ExtraBold" by family and weight.
class LogosBrandKitTypefacesTest < Minitest::Test
  BrandKit = Logos::BrandKit

  def levels(brand) = BrandKit.new(brand).typefaces.map { |typeface| [typeface.role, typeface.name, typeface.weight] }

  def refusal(typefaces)
    styles = { "kit" => Logos::NavbarLogo.styles.fetch("studio").merge("typefaces" => typefaces) }
    assert_raises(Logos::NavbarLogo::Error) { BrandKit.new("kit", styles:) }.message
  end

  def montserrat(role, weight) = { "role" => role, "family" => "Montserrat", "weight" => weight }

  def test_each_brands_hierarchy_as_alex_asked
    assert_equal [["Display", "Montserrat ExtraBold", 800], ["Text", "Montserrat Light", 300], ["Tagline", "Montserrat Medium", 500]], levels("studio")
    assert_equal [["Display", "Montserrat Bold", 700], ["Text", "Montserrat Light", 300], ["Tagline", "Montserrat Medium", 500]], levels("industries")
    assert_equal [["Display", "Montserrat ExtraBold", 800], ["Text", "Montserrat Medium", 500]], levels("turf")
    assert_equal [["Display", "Traced lettering (face not identified)", nil], ["Tagline", "Montserrat Medium", 500]], levels("welding")
  end

  def test_only_the_traced_level_is_traced
    assert_equal [true, false], BrandKit.new("welding").typefaces.map(&:traced?)
    assert_nil BrandKit.new("welding").typefaces.first.family
    refute BrandKit.all.reject { |kit| kit.brand == "welding" }.flat_map(&:typefaces).any?(&:traced?)
  end

  def test_no_more_than_three_levels_and_at_least_one
    assert_match(/1 to 3 levels/, refusal([montserrat("A", 800), montserrat("B", 500), montserrat("C", 300), montserrat("D", 300)]))
    assert_match(/1 to 3 levels/, refusal([]))
    assert_match(/1 to 3 levels/, refusal(nil))
    assert_equal 3, BrandKit::MAX_LEVELS
  end

  def test_a_family_must_be_one_the_hub_serves
    assert_match(/family must be one of Montserrat, got "Inter"/, refusal([{ "role" => "Display", "family" => "Inter", "weight" => 700 }]))
  end

  def test_a_weight_must_be_a_named_one
    [450, "800", nil, 1000].each do |bad|
      assert_match(/weight must be one of 100, .*900/, refusal([montserrat("Display", bad)]), bad.inspect)
    end
  end

  def test_a_traced_level_has_a_label_and_no_weight_and_a_font_level_no_label
    assert_match(/traced lettering, so it takes no weight/, refusal([{ "role" => "Display", "label" => "Traced", "weight" => 800 }]))
    assert_match(/typeface Display label must be plain words/, refusal([{ "role" => "Display" }]))
    assert_match(/takes no label/, refusal([montserrat("Display", 800).merge("label" => "Big")]))
  end

  def test_a_level_needs_a_plain_role_and_only_known_keys
    assert_match(/with a role/, refusal([{ "family" => "Montserrat", "weight" => 800 }]))
    assert_match(/with a role/, refusal([montserrat("Display", 800).merge("size" => 30)]))
    assert_match(/typeface role must be plain words/, refusal([montserrat("<b>Display</b>", 800)]))
  end
end
