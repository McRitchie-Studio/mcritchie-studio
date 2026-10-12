# frozen_string_literal: true

require "test_helper"

# [integration] A saved kit choice round-trips into the drawn SVG (task brand-kit-record): the choice saved from the
# brand page's form, read back from the database, is drawn by the table and the Kit card exactly as the library
# draws the same choice from the page's URL, byte for byte; and a choice saved with no edits draws exactly the logo
# the page draws with none, so a saved kit never changes an unedited logo's bytes.
class BrandKitRoundTripTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def svg_at(src)
    get src
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    response.body
  end

  def saved_srcs(brand, type)
    get logos_path
    index = css_select("[data-brand='#{brand}'] [data-test='logo-sample'][data-type='#{type}'] img").map { |img| img["src"] }
    get logo_brand_path(brand)
    card = css_select("[data-test='kit-pick'][data-type='#{type}'] img").map { |img| img["src"] }
    [index, card]
  end

  test "a saved stacked choice with edits is drawn in the table and the Kit card as the page drew it from its URL" do
    page = { type: "stacked", form: "tagline", ending_colour: "8E82FE", first_weight: "600", tagline_visible: "0" }
    get logo_brand_path("studio", page)
    form = css_select("form[data-test='kit-save-form']").first
    fields = form.css("input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
    patch form["action"], params: fields.merge("text" => "second")
    assert_response :redirect

    logo = Logos::StackedLogo.new("studio")
    edits = logo.checked_edits(Logos::Variant.edits(page))
    index, card = saved_srcs("studio", :stacked)
    assert_equal 2, index.size
    assert_equal index, card, "the table and the Kit card draw the same logo"
    index.each do |src|
      tone = Rack::Utils.parse_query(URI(src).query).fetch("tone").to_sym
      expected = Logos::Variant.new(logo, type: :stacked, form: :tagline, text: :second, tone:, edits:).svg
      assert_equal expected, svg_at(src), tone
      assert_includes expected, 'fill="#8E82FE"' if tone == :light
      shown = Logos::Variant.new(logo, type: :stacked, form: :tagline, text: :second, tone:, edits: edits.except(:tagline)).svg
      assert_operator expected.scan("<path").size, :<, shown.scan("<path").size, "the hidden tagline's letters are not drawn"
    end
  end

  # The table draws one icon per row (task kit-icon-atomic-unit): with no kit icon saved, the brand's own (Industries'
  # Original), so an Alt choice is drawn there with the Original icon; the kit card draws it exactly as saved.
  test "a saved navbar choice with no edits draws byte for byte the logo the page draws, in every baked tone" do
    BrandKit.for("industries").save_choice(:navbar, ActionController::Parameters.new(rule: "6", text: "first"), by: "alex@test.com")
    index, card = saved_srcs("industries", :navbar)
    logo = Logos::NavbarLogo.new("industries")
    Logos::NavbarLogo::BAKED.each_with_index do |tone, at|
      assert_equal logo.svg(rule: 6, text: :first, tone:, icon_colouring: :original), svg_at(index.fetch(at)), tone
      assert_equal logo.svg(rule: 6, text: :first, tone:), svg_at(card.fetch(at)), tone
    end
    refute_match(/custom/, index.join, "an unedited choice's file is not named custom")
  end

  # With nothing saved the brand's own colouring is shown: Turf Monster's Original (task logo-original-and-alt).
  test "with nothing saved the table draws exactly what it drew before the kit record, in the brand's own colouring" do
    get logos_path
    srcs = css_select("[data-brand='turf'] [data-test='logo-sample'] img").map { |img| img["src"] }
    navbar = Logos::NavbarLogo.new("turf")
    stacked = Logos::StackedLogo.new("turf")
    expected = Logos::NavbarLogo::BAKED.flat_map { |tone| [stacked.svg(text: :first, tone:, colouring: :original)] } +
               Logos::NavbarLogo::BAKED.map { |tone| navbar.svg(rule: 4, text: :second, tone:, colouring: :original) } +
               Logos::NavbarLogo::BAKED.map { |tone| navbar.icon_svg(tone:, colouring: :original) }
    assert_equal expected, srcs.map { |src| svg_at(src) }
  end
end
