# frozen_string_literal: true

require "test_helper"

# [component] THE KIT'S ICON through the routes (task kit-icon-atomic-unit): the Icon tab saves it with Save as default
# and clears it; the Navbar and Stacked tabs then draw it (their Colouring sets the words), their Edit panel's Icon row
# defers to the Icon tab, and the URL may still explore another icon; the /logos table draws one icon per row.
class LogosKitIconTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def form_fields(form) = form.css("input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
  def query(src) = Rack::Utils.parse_query(URI(src).query.to_s)
  def logo_srcs = css_select("[data-test='logo-type'] img[data-test='logo-image']").map { |img| img["src"] }

  def save_icon(brand, **page)
    get logo_brand_path(brand, type: "icon", **page)
    form = css_select("form[data-test='kit-save-default-form']").first
    patch form["action"], params: form_fields(form)
  end

  test "the Icon tab saves the kit's icon from its control row and clears it from the Kit choice card" do
    get logo_brand_path("welding_v2", type: "icon")
    assert_select "[data-test='logo-controls'] [data-test='kit-save-default']", 1
    assert_select "[data-test='kit-default-state'][data-state='none']"

    save_icon("welding_v2", colouring: "alt", icon_colour: "D7602E")
    assert_redirected_to logo_brand_path("welding_v2", type: "icon")
    assert_match(/\ASaved the Icon kit choice: alt colouring, icon /, flash[:notice])
    assert_equal({ "colouring" => "alt", "edits" => { "icon_colour" => "D7602E" } }, BrandKit.find_by(brand: "welding_v2").icon_choice)

    get logo_brand_path("welding_v2", type: "icon")
    assert_select "[data-test='kit-default-state'][data-state='shown']"
    assert_select "[data-test='kit-save-default'][disabled]"
    assert_equal [%w[alt D7602E]] * 2, logo_srcs.map { |src| query(src).values_at("colouring", "icon_colour").map { |v| v || "alt" } }
    assert_select "[data-test='kit-pick'][data-type='icon'][data-saved='true']"

    delete brand_kit_choice_path("welding_v2"), params: { type: "icon" }
    assert_equal "Cleared the Icon kit choice. Each logo draws its own icon again.", flash[:notice]
    assert_nil BrandKit.find_by(brand: "welding_v2").icon_choice
  end

  test "the Navbar and Stacked tabs draw the kit's icon, and their Colouring sets the words" do
    save_icon("welding_v2")   # the brand's own: Original
    get logo_brand_path("welding_v2", colouring: "alt")
    assert_equal 6, logo_srcs.size
    logo_srcs.each { |src| assert_equal [nil, "original"], query(src).values_at("colouring", "icon_colouring"), src }
    assert_select "[data-test='kit-icon-note']", /The icon is the kit's \(original colouring\), so Colouring here sets the words/
    assert_select "[data-test='kit-icon-tab'][href=?]", logo_brand_path("welding_v2", type: "icon", colouring: "alt")

    get logo_brand_path("welding_v2", type: "stacked", colouring: "alt")
    logo_srcs.each { |src| assert_equal "original", query(src)["icon_colouring"] }
    get logo_brand_path("welding_v2", type: "stacked")
    logo_srcs.each { |src| assert_equal ["original", nil], query(src).values_at("colouring", "icon_colouring"), "Original words, the same icon" }
  end

  test "under a kit icon the Edit panel's Icon row shows it and sends the reader to the Icon tab" do
    save_icon("studio", icon_colour: "635BB2")
    get logo_brand_path("studio")
    icon_row = css_select("[data-test='edit-row'][data-part='icon']").first
    assert icon_row.at_css("[data-test='edit-kit-icon']")
    assert_equal "Uses the kit icon. Change it on the Icon tab.", icon_row.at_css("[data-test='edit-kit-icon'] p").text.squish
    assert_equal logo_brand_path("studio", type: "icon"), icon_row.at_css("[data-test='edit-kit-icon-link']")["href"]
    assert_equal "#635BB2", icon_row.at_css("[data-test='edit-kit-icon-colour']")["style"][/#\h{6}/]
    assert_empty icon_row.css("input[name=icon_colour]"), "no picker: the form never sends the icon's colour"
    assert_equal 2, icon_row.css("img[data-test='edit-kit-icon-image']").size
    logo_srcs.each { |src| assert_equal "635BB2", query(src)["icon_colour"] }

    # The URL may still explore another icon: the row is the picker again, and the page says how to come back.
    get logo_brand_path("studio", icon_colour: "8E82FE")
    assert_select "[data-test='edit-row'][data-part='icon'] input[name=icon_colour]"
    assert_select "[data-test='edit-kit-icon']", 0
    logo_srcs.each { |src| assert_equal "8E82FE", query(src)["icon_colour"] }
    assert_select "[data-test='kit-icon-back'][href=?]", logo_brand_path("studio")
  end

  test "an icon colouring in the URL explores on the Navbar tab, with or without a kit icon" do
    get logo_brand_path("welding_v2", colouring: "alt", icon_colouring: "original")
    logo_srcs.each { |src| assert_equal "original", query(src)["icon_colouring"] }
    assert_select "[data-test='kit-icon-note']", 0, "no kit icon to come back to"
    assert_select "[data-test='logo-tab'][data-type='stacked'][href*='icon_colouring=original']"
    get logo_brand_path("studio", icon_colouring: "original")
    logo_srcs.each { |src| assert_nil query(src)["icon_colouring"], "Studio has no original: its icon is Alt like its words" }
  end

  test "with no kit icon saved, the brand page draws exactly as before" do
    get logo_brand_path("welding_v2", colouring: "alt")
    logo_srcs.each { |src| refute_includes query(src).keys, "icon_colouring" }
    assert_select "[data-test='edit-kit-icon'], [data-test='kit-icon-note']", 0
    assert_select "[data-test='edit-row'][data-part='icon'] input[name=icon_colour]"
  end

  test "a Navbar saved under a kit icon stores no icon colour of its own" do
    save_icon("studio", icon_colour: "635BB2")
    get logo_brand_path("studio", rule: 3, first_colour: "8E82FE")
    form = css_select("form[data-test='kit-save-default-form']").first
    refute_includes form_fields(form).keys, "icon_colour"
    patch form["action"], params: form_fields(form).merge("icon_colour" => "1A1535")
    assert_equal({ "first_colour" => "8E82FE" }, BrandKit.find_by(brand: "studio").navbar_choice["edits"])
  end

  # Item 5: the watermark is still the single-colour icon, and a dark page draws the dark tone of the kit icon's colouring.
  test "the watermark draws the single-colour icon and a dark page the kit icon's dark tone" do
    save_icon("welding_v2")   # Original
    get logo_brand_path("welding_v2", colouring: "alt", context: "watermark")
    assert_equal 3, logo_srcs.size
    logo_srcs.each { |src| assert_equal ["watermark", nil, nil], query(src).values_at("tone", "colouring", "icon_colouring"), src }
    assert_equal Logos::NavbarLogo.new("welding_v2").svg(rule: 4, text: :second, tone: :watermark), Logos::Variant.parse(Logos::NavbarLogo.new("welding_v2"), query(logo_srcs.last).symbolize_keys).svg

    get logo_brand_path("welding_v2", colouring: "alt")
    dark = logo_srcs.select { |src| query(src)["tone"] == "dark" }
    assert_equal 3, dark.size
    dark.each { |src| assert_equal "original", query(src)["icon_colouring"] }
    get dark.first
    text = query(dark.first)["text"].to_sym
    assert_equal Logos::NavbarLogo.new("welding_v2").svg(rule: 4, text:, tone: :dark, colouring: :alt, icon_colouring: :original), response.body,
                 "the Original helmet's dark tone (its white half holds on a dark page), with Alt words"
  end

  test "each /logos row draws one icon in all three tiles: the kit's, else the brand's own" do
    BrandKit.for("welding_v2").save_choice(:stacked, ActionController::Parameters.new(form: "tagline", text: "first", colouring: "alt"), by: "alex@test.com")
    get logos_path
    row = ->(brand) { css_select("[data-test='logo-cluster'][data-brand='#{brand}'] img").map { |img| query(img["src"]) } }
    icons = ->(srcs) { srcs.map { |src| src["icon_colouring"] || src["colouring"] || "alt" }.uniq }
    assert_equal %w[original], icons.(row.("welding_v2")), "no kit icon: the brand's own Original, in all three tiles"

    save_icon("welding_v2", colouring: "alt")
    get logos_path
    assert_equal %w[alt], icons.(row.("welding_v2")), "the kit's Alt icon, in all three tiles"
    assert_select "[data-test='logo-cluster'][data-brand='welding_v2'] [data-test='logo-sample'][data-type='icon'] [data-test='logo-badge']", "Icon · Saved"
  end
end
