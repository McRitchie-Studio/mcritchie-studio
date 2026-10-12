# frozen_string_literal: true

require "test_helper"

# [component] The brand page's EDIT panel (task logo-part-editor, Alex's item 4b) through the routes: a row per part
# on the Navbar and Stacked tabs (the Tagline row on the tagline form only), the brand's palette as the only colours,
# a weight per word (disabled, with a reason, for traced lettering), the tagline's visibility, edits carried by every
# other control and applied to every logo on the tab, a Reset, the watermark's refusal, and the 422s.
class LogosEditPanelTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def rows = css_select("[data-test='edit-row']")
  def row_parts = rows.map { |row| row["data-part"] }
  def logo_srcs = css_select("img[data-test='logo-image']").map { |img| img["src"] }
  def query(href) = Rack::Utils.parse_query(URI(href).query.to_s)
  # The edits apply to Alt only (task logo-original-and-alt). A brand page opens on the brand's Original where it has
  # one, so these pages ask for Alt; Studio has only Alt and takes no param.
  def page(brand, **params) = logo_brand_path(brand, **(Logos::NavbarLogo.new(brand).original? ? { colouring: "alt" } : {}), **params)

  test "the Navbar and Stacked tabs have an edit panel naming each part and the brand's own words; the Icon tab, the icon alone" do
    get page("studio")
    assert_equal %w[icon first ending], row_parts
    assert_equal %w[McRITCHIE STUDIO], css_select("[data-test='edit-word']").map { |w| w.text.strip }

    get page("industries", type: "stacked")
    assert_equal %w[icon first ending], row_parts, "the two-line form has no tagline row"
    get page("industries", type: "stacked", form: "tagline")
    assert_equal %w[icon first ending tagline], row_parts
    assert_equal %w[McRITCHIE INDUSTRIES], css_select("[data-test='edit-word']").map { |w| w.text.strip }.first(2)
    assert_equal "BUILD BETTER", css_select("[data-test='edit-word']").last.text.strip

    get page("turf", type: "stacked")
    assert_equal %w[icon first ending], row_parts, "Turf Monster has no tagline"
    assert_equal %w[Turf Monster], css_select("[data-test='edit-word']").map { |w| w.text.strip }

    get page("studio", type: "icon")
    assert_equal %w[icon], row_parts, "the icon's colour, the kit icon's (task kit-icon-atomic-unit)"
  end

  test "each part's colours are the brand's palette, with As styled marked until one is picked" do
    get page("industries")
    palette = Logos::BrandKit.new("industries").palette.map(&:hex)
    rows.each do |row|
      swatches = row.css("[data-test='edit-swatch']")
      assert_equal [""] + palette, swatches.map { |s| s["data-hex"] }, row["data-part"]
      assert_equal [""], row.css("input[type=radio][checked]").map { |r| r["value"] }, "#{row['data-part']}: as styled"
    end

    get page("industries", ending_colour: "c8661f")
    ending = css_select("[data-test='edit-row'][data-part='ending']").first
    assert_equal ["C8661F"], ending.css("input[type=radio][checked]").map { |r| r["value"] }
    assert_equal "#C8661F", ending.at_css("[data-edit-contrast]")["data-edit-contrast"]
    assert_equal "Forge Orange", ending.at_css("[data-edit-contrast]")["data-name"]
  end

  test "the icon row says which layer it recolours" do
    { "studio" => "Recolours the whole icon.", "industries" => "Recolours the icon's main layer only; its edge layer keeps its brand colour.",
      # Turf Monster's Alt head is single-colour (task logo-original-and-alt); its three-colour head is the Original.
      "turf" => "Recolours the whole icon." }.each do |brand, note|
      get page(brand)
      assert_equal note, css_select("[data-test='edit-icon-note']").first.text.strip, brand
    end
  end

  # Task logo-gallery-polish-pass, item 1: Commercial Welding's dark tone draws the one-layer helmet, so in Dark the
  # icon colour recolours all of it; the note follows the icon each tone draws.
  test "the icon note follows the icon each tone draws: Commercial Welding's dark helmet is one layer" do
    %w[welding welding_v2].each do |brand|
      get page(brand)
      notes = css_select("[data-test='edit-icon-note'] [data-test='edit-icon-note-tone']").to_h { |span| [span["data-tone"], [span.text.strip, span["class"]]] }
      assert_equal({ "light" => ["Recolours the icon's main layer only; its accent layer keeps its brand colour.", "contents dark:hidden"],
                     "dark" => ["Recolours the whole icon.", "hidden dark:contents"] }, notes, brand)
    end

    get page("industries")
    assert_empty css_select("[data-test='edit-icon-note-tone']"), "one note when every tone draws the same icon"
  end

  test "each word offers the six weights; traced lettering's weight is disabled with its reason" do
    get page("studio", first_weight: 300)
    selects = css_select("select[data-test='edit-weight']")
    assert_equal %w[first_weight ending_weight], selects.map { |s| s["name"] }
    assert_equal ["", "300", "400", "500", "600", "700", "800"], selects.first.css("option").map { |o| o["value"] }
    assert_equal "300", selects.first.at_css("option[selected]")["value"]
    assert_empty css_select("[data-test='edit-weight-reason']")

    get page("welding", type: "stacked", form: "tagline")
    selects = css_select("select[data-test='edit-weight']")
    assert_equal [true, true, false], selects.map { |s| s.key?("disabled") }, "the words are traced; the tagline is Montserrat"
    assert_equal ["The name is traced lettering, which has one weight."] * 2, css_select("[data-test='edit-weight-reason']").map { |r| r.text.strip }
  end

  test "the tagline can be shown or hidden" do
    get page("studio", type: "stacked", form: "tagline")
    visible = css_select("[data-test='edit-visible'] input[type=radio]")
    assert_equal [["", true], ["0", false]], visible.map { |r| [r["value"], r.key?("checked")] }
    get page("studio", type: "stacked", form: "tagline", tagline_visible: 0)
    assert_equal [["", false], ["0", true]], css_select("[data-test='edit-visible'] input[type=radio]").map { |r| [r["value"], r.key?("checked")] }
    logo_srcs.each { |src| assert_equal "0", query(src)["tagline_visible"], src }
    # Task logo-gallery-polish-pass, item 3: the pictures' alt text says the tagline is hidden.
    alts = css_select("[data-test='logo-example'] img").map { |img| img["alt"] }
    assert_equal 6, alts.size
    alts.each { |alt| assert_match(/, tagline hidden, /, alt) && refute_match(/with tagline/, alt) }
  end

  test "edits reach every logo on the tab, in both tones, and the drawn SVG carries the picked colour" do
    get page("studio", type: "stacked", form: "tagline", first_colour: "635BB2", tagline_visible: 0)
    assert_equal 6, logo_srcs.size, "three text versions, light and dark"
    logo_srcs.each { |src| assert_equal "635BB2", query(src)["first_colour"], src }

    get logo_srcs.first
    assert_includes response.body, %(fill="#635BB2")
    assert_equal Logos::StackedLogo.new("studio").svg(form: :tagline, text: :homogeneous, edits: { first: { colour: "#635BB2" }, tagline: { visible: false } }), response.body
  end

  test "no edits leaves every logo's address as it was" do
    get page("industries")
    logo_srcs.each { |src| assert_empty query(src).keys & Logos::Variant::EDIT_PARAMS.keys.map(&:to_s), src }
    assert_empty css_select("[data-test='edit-reset']")
  end

  test "every other control carries the edits, the edit form carries every other setting, and Reset drops only the edits" do
    get page("industries", rule: 6, guides: 1, ending_weight: 300, icon_colour: "E07B2E")
    edits = { "ending_weight" => "300", "icon_colour" => "E07B2E" }
    links = css_select("[data-test='logo-tab'], [data-test='rule-option'], [data-test='guides-toggle']").map { |a| a["href"] }
    links.each { |href| assert_equal edits, query(href).slice(*edits.keys), href }
    context_hidden = css_select("[data-test='context-form'] input[type=hidden]").to_h { |i| [i["name"], i["value"]] }
    assert_equal edits, context_hidden.slice(*edits.keys)

    form_hidden = css_select("[data-test='edit-form'] input[type=hidden]").to_h { |i| [i["name"], i["value"]] }
    assert_equal({ "colouring" => "alt", "rule" => "6", "guides" => "1" }, form_hidden)

    reset = query(css_select("[data-test='edit-reset']").first["href"])
    assert_equal({ "colouring" => "alt", "rule" => "6", "guides" => "1" }, reset)
  end

  test "the stacked form links carry the edits, and a tagline edit survives the trip through the two-line form" do
    get page("studio", type: "stacked", form: "tagline", tagline_colour: "8E82FE", first_weight: 600)
    two_line = css_select("[data-test='form-option'][data-form='two_line']").first["href"]
    assert_equal({ "type" => "stacked", "tagline_colour" => "8E82FE", "first_weight" => "600" }, query(two_line))
    get two_line
    logo_srcs.each { |src| assert_nil query(src)["tagline_colour"], "the two-line form draws no tagline: #{src}" }
    tagline = css_select("[data-test='form-option'][data-form='tagline']").first["href"]
    assert_equal "8E82FE", query(tagline)["tagline_colour"]
  end

  test "in Watermark the edits do not apply, the panel says so, and they are kept for Light and Dark" do
    get page("studio", context: "watermark", first_colour: "635BB2")
    assert_match(/edits do not apply here/, css_select("[data-test='edit-watermark']").text)
    assert_empty css_select("[data-test='edit-form']")
    logo_srcs.each { |src| assert_nil query(src)["first_colour"], src }
    assert_equal "635BB2", query(css_select("[data-test='logo-tab']").first["href"])["first_colour"]
  end

  test "a colour outside the palette, a bad weight or visibility, and a tagline edit for a brand without one are 422s" do
    { page("studio", first_colour: "000000") => /first's colour must be one of the brand's palette/,
      page("studio", first_colour: "red") => /unknown first_colour "red": expected a six-digit hex/,
      page("studio", ending_weight: 900) => /ending's weight must be one of 300, 400, 500, 600, 700, 800/,
      page("studio", ending_weight: "bold") => /unknown ending_weight "bold"/,
      page("studio", type: "stacked", form: "tagline", tagline_visible: "no") => /unknown tagline_visible "no": expected 0 or 1/,
      page("welding", first_weight: 700) => /traced lettering, which has one weight/,
      page("turf", tagline_colour: "4BAF50") => /brand turf: it has no tagline to edit/,
      navbar_logo_path("studio", icon_colour: "123456") => /icon's colour must be one of the brand's palette/ }.each do |path, message|
      get path
      assert_response :unprocessable_content, path
      assert_match message, response.body, path
      assert_equal "text/plain", response.media_type
    end
  end

  test "every download and copy on the tab honours the edits, and an edited file is named -custom" do
    get page("industries", rule: 4, ending_weight: 300, ending_colour: "C8661F")
    downloads = css_select("a[data-test='logo-download']")
    copies = css_select("button[data-test='logo-copy']")
    assert_equal 6, downloads.size
    assert_equal 6, copies.size
    logo = Logos::NavbarLogo.new("industries")
    edits = { ending: { weight: 300, colour: "#C8661F" } }
    expected = Logos::Variant::TEXTS.keys.product(Logos::NavbarLogo::BAKED).map { |text, tone| logo.svg(rule: 4, text:, tone:, edits:) }
    fetched = copies.map do |button|
      get button["data-copy-svg"]
      response.body
    end
    assert_equal expected.sort, fetched.sort, "each copy fetches the edited logo"
    copies.each { |b| assert_match(/, edited\z/, b["aria-label"]) }

    downloads.each do |link|
      assert_equal %w[300 C8661F 1], query(link["href"]).values_at("ending_weight", "ending_colour", "download")
      get link["href"]
      assert_response :success
      assert_match(/attachment; filename="industries-navbar-rule4-\w+-(light|dark)-custom\.svg"/, response.headers["Content-Disposition"])
      assert_includes response.body, %(fill="#C8661F")
    end
  end

  test "an unedited download keeps its old name" do
    get navbar_logo_path("industries", rule: 4, text: "second", download: 1)
    assert_match(/filename="industries-navbar-rule4-second-light\.svg"/, response.headers["Content-Disposition"])
  end

  test "Commercial Welding v1's ending row names its whole traced ending, and v2 gets the panel with its weights disabled" do
    get page("welding", type: "stacked", form: "tagline")
    assert_equal ["COMMERCIAL", "WELDING LLC", "BUILDING STRONG CONNECTIONS"], css_select("[data-test='edit-word']").map { |w| w.text.strip }

    get page("welding_v2")
    assert_equal %w[icon first ending], row_parts
    assert_equal %w[COMMERCIAL WELDING], css_select("[data-test='edit-word']").map { |w| w.text.strip }
    assert(css_select("select[data-test='edit-weight']").all? { |s| s.key?("disabled") }, "traced lettering: one weight")
    assert_equal ["The name is traced lettering, which has one weight."] * 2, css_select("[data-test='edit-weight-reason']").map { |r| r.text.strip }

    get page("welding_v2", type: "stacked", form: "tagline", ending_colour: "D7602E", tagline_weight: 700)
    assert_response :success
    assert_equal %w[icon first ending tagline], row_parts
    logo_srcs.each { |src| assert_equal %w[D7602E 700], query(src).values_at("ending_colour", "tagline_weight"), src }

    get page("welding_v2", first_weight: 700)
    assert_response :unprocessable_content
    assert_match(/traced lettering, which has one weight/, response.body)
  end

  # Task logo-compare-and-original-edits (Alex 2026-10-11 23:06): the word rows work in Original. The words take the
  # edit and the icon stays the brand's art; only the Icon row needs Alt, and says so with a link that recolours the
  # icon alone.
  test "on the Original the word rows edit the words and the Icon row sends its colour to Alt" do
    get logo_brand_path("industries", ending_colour: "C8661F")
    assert_equal %w[icon first ending], row_parts
    assert_select "[data-test='edit-original']", 0
    assert_select "[data-test='edit-row'][data-part='ending'] input[type=radio][value='C8661F'][checked]"
    assert_select "[data-test='edit-icon-original']", /The icon is the brand's original art, so its colour changes in Alt only/
    alt = css_select("[data-test='edit-icon-in-alt']").first["href"]
    assert_equal({ "icon_colouring" => "alt", "ending_colour" => "C8661F" }, query(alt), "the words stay Original; the icon goes to Alt")
    logo_srcs.each do |src|
      assert_equal "original", query(src)["colouring"], src
      assert_equal "C8661F", query(src)["ending_colour"], "the Original draws the word edit: #{src}"
    end

    get logo_brand_path("industries", type: "icon")
    assert_equal %w[icon], row_parts
    assert_equal({ "type" => "icon", "colouring" => "alt" }, query(css_select("[data-test='edit-icon-in-alt']").first["href"]))
  end

  test "the Navbar and Stacked tabs show the same edit rows in the same order, in Original and in Alt" do
    %w[welding_v2 industries].each do |brand|
      [{}, { colouring: "alt" }].each do |colouring|
        get logo_brand_path(brand, **colouring)
        navbar = rows.map { |row| [row["data-part"], row.css("[data-test='edit-swatch']").size, row.css("select[data-test='edit-weight']").size] }
        get logo_brand_path(brand, type: "stacked", **colouring)
        stacked = rows.map { |row| [row["data-part"], row.css("[data-test='edit-swatch']").size, row.css("select[data-test='edit-weight']").size] }
        assert_equal navbar, stacked, "#{brand} #{colouring}"
        assert_equal %w[icon first ending], navbar.map(&:first)
      end
    end
  end

  # Alex's reproduction: on welding_v2's Stacked tab in Original, colour the first word orange and save it as the
  # default. The tab then opens on the Original helmet with orange words, not on Alt's single-colour helmet.
  test "welding_v2 Stacked saved in Original with an orange first word keeps the Original helmet" do
    get logo_brand_path("welding_v2", type: "stacked", first_colour: "D7602E")
    fields = css_select("form[data-test='kit-save-default-form'] input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
    assert_equal "original", fields["colouring"]
    assert_equal "D7602E", fields["first_colour"]
    patch brand_kit_choice_path("welding_v2"), params: fields.except("_method", "authenticity_token")
    choice = BrandKit.for("welding_v2").stacked_choice
    assert_equal "original", choice["colouring"]
    assert_equal({ "first_colour" => "D7602E" }, choice["edits"])

    get logo_brand_path("welding_v2", type: "stacked")
    assert_select "[data-test='kit-default-state'][data-state='shown']"
    logo_srcs.each do |src|
      assert_equal "original", query(src)["colouring"], src
      assert_equal "D7602E", query(src)["first_colour"], src
      assert_nil query(src)["icon_colouring"], "the icon is the words' Original: #{src}"
    end
    svg = BrandKit.for("welding_v2").variant(:stacked).svg
    assert_includes svg, 'fill="#2E5E8E"', "the Original helmet's blue"
    assert_includes svg, 'fill="#D7602E"'
  end
end
