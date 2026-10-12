# frozen_string_literal: true

require "test_helper"

# [component] Logo COLOURINGS through the routes (task logo-original-and-alt): every SVG endpoint takes
# ?colouring=original|alt (Alt unless asked, so every existing URL serves what it served), names an Original's file
# -original, and refuses an Original of a brand that has none.
class LogosColouringPagesTest < ActionDispatch::IntegrationTest
  # The colouring an SVG route's src names: an icon always names its own, Alt included (task kit-export-and-clear-lens:
  # an icon asked with no colouring draws the brand's kit icon); a Navbar or Stacked Logo names only an Original.
  def named(src, colouring) = src.include?("/icon?") ? (colouring || "alt") : colouring

  setup { log_in_as(users(:alex)) }

  def disposition = response.headers["Content-Disposition"]

  test "every SVG endpoint serves the Original when asked, as a file named -original" do
    navbar = Logos::NavbarLogo.new("welding")
    stacked = Logos::StackedLogo.new("welding")
    {
      icon_logo_path("welding", tone: "dark", colouring: "original", download: 1) =>
        [navbar.icon_svg(tone: :dark, colouring: :original), "welding-icon-dark-original.svg"],
      navbar_logo_path("welding", rule: 3, text: "first", tone: "light", colouring: "original", download: 1) =>
        [navbar.svg(rule: 3, text: :first, tone: :light, colouring: :original), "welding-navbar-rule3-first-light-original.svg"],
      stacked_logo_path("welding", form: "tagline", text: "first", tone: "dark", colouring: "original", download: 1) =>
        [stacked.svg(form: :tagline, text: :first, tone: :dark, colouring: :original), "welding-stacked-tagline-first-dark-original.svg"]
    }.each do |path, (svg, filename)|
      get path
      assert_response :success
      assert_equal svg, response.body, path
      assert_match(/\Aattachment; filename="#{Regexp.escape(filename)}"/, disposition)
    end
  end

  test "an endpoint draws Alt unless asked, exactly as before, and colouring=alt is the same file" do
    alt = Logos::NavbarLogo.new("welding").svg(rule: 4, text: :second, tone: :dark)
    [{}, { colouring: "alt" }].each do |more|
      get navbar_logo_path("welding", { rule: 4, text: "second", tone: "dark" }.merge(more))
      assert_equal alt, response.body
      assert_match(/filename="welding-navbar-rule4-second-dark\.svg"/, disposition)
    end
  end

  test "a watermark has no colouring: asking for the Original serves the one-colour watermark" do
    get icon_logo_path("welding", tone: "watermark", colouring: "original")
    assert_response :success
    assert_equal Logos::NavbarLogo.new("welding").icon_svg(tone: :watermark), response.body
    assert_match(/filename="welding-icon-watermark\.svg"/, disposition)
  end

  test "an Original of a brand with none, or an unknown colouring, is a 422 in plain text" do
    get navbar_logo_path("studio", colouring: "original")
    assert_response :unprocessable_content
    assert_equal "brand studio: it has no original colouring (its logo is solid colour), so only alt", response.body
    get icon_logo_path("welding", colouring: "sepia")
    assert_response :unprocessable_content
    assert_match(/unknown colouring "sepia": expected one of original, alt/, response.body)
  end

  def query(href) = Rack::Utils.parse_query(URI(href).query.to_s)
  def srcs = css_select("img[data-test='logo-image']").map { |img| img["src"] }
  def options = css_select("[data-test='colouring-option']")

  test "a brand page opens on the brand's Original, with a Colouring control beside Context" do
    get logo_brand_path("welding", type: "stacked")
    assert_response :success
    assert_select "[data-test='context-form'] ~ [data-test='colouring-control']", 1, "beside Context"
    assert_equal %w[original alt], options.map { |option| option["data-colouring"] }
    assert_equal ["original"], css_select("[data-test='colouring-option'][aria-current='true']").map { |option| option["data-colouring"] }
    assert_equal 6, srcs.size
    srcs.each { |src| assert_equal "original", query(src)["colouring"], src }
    css_select("a[data-test='logo-download']").each { |link| assert_equal "original", query(link["href"])["colouring"] }
    assert_select "img[data-test='logo-image'][alt$='original colouring']", 6
    assert_select "[data-test='colouring-note']", /Original is the brand's own art/
  end

  test "Alt draws today's logos, and the colouring is kept across every other control" do
    get logo_brand_path("industries", colouring: "alt", rule: 3)
    srcs.each { |src| assert_nil query(src)["colouring"], "an Alt logo's URL is as before: #{src}" }
    assert_equal ["alt"], css_select("[data-test='colouring-option'][aria-current='true']").map { |option| option["data-colouring"] }
    links = css_select("[data-test='logo-tab'], [data-test='rule-option'], [data-test='guides-toggle'], [data-test='logos-crumb']").map { |a| a["href"] }
    links.each { |href| assert_equal "alt", query(href)["colouring"], href }
    hidden = css_select("[data-test='context-form'] input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
    assert_equal "alt", hidden["colouring"]
    original = css_select("[data-test='colouring-option'][data-colouring='original']").first["href"]
    assert_equal({ "rule" => "3" }, query(original), "Original is the default, so choosing it drops the param and keeps the rest")
  end

  test "the index shows each brand's Original where it has one, and Alt on asking" do
    get logos_path
    assert_select "[data-test='colouring-control']", 1
    { "welding" => "original", "industries" => "original", "turf" => "original", "studio" => nil }.each do |brand, colouring|
      css_select("[data-brand='#{brand}'] [data-test='logo-sample'] img").each { |img| assert_equal named(img["src"], colouring), query(img["src"])["colouring"], brand }
    end
    get logos_path(colouring: "alt")
    css_select("[data-test='logo-sample'] img").each { |img| assert_equal named(img["src"], nil), query(img["src"])["colouring"], img["src"] }
    css_select("[data-test='logo-brand-row'] th a").each { |link| assert_equal "alt", query(link["href"])["colouring"], "the brand links keep it" }
  end

  test "a kit choice saves the page's colouring, and a choice saved before colourings reads as Alt" do
    get logo_brand_path("welding", type: "stacked", form: "tagline")
    form = css_select("form[data-test='kit-save-form']").first
    fields = form.css("input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
    assert_equal "original", fields["colouring"]
    patch form["action"], params: fields.merge("text" => "first")
    assert_response :redirect
    assert_equal({ "form" => "tagline", "text" => "first", "colouring" => "original", "edits" => {} }, BrandKit.for("welding").stacked_choice)
    assert_equal :original, BrandKit.for("welding").variant(:stacked).colouring

    legacy = BrandKit.for("industries")
    legacy.update!(navbar_choice: { "rule" => 4, "text" => "first", "edits" => {} }, updated_by: "alex@test.com")
    assert_equal :alt, legacy.variant(:navbar).colouring, "no colouring saved: what it showed then"
    assert_equal :original, legacy.variant(:navbar, colouring: :original).colouring, "the table may ask for the Original"
    assert_equal :alt, BrandKit.for("studio").variant(:navbar, colouring: :original).colouring, "a brand with none draws Alt"
  end

  test "an unknown page colouring is a 422 in plain text" do
    get logo_brand_path("welding", colouring: "sepia")
    assert_response :unprocessable_content
    assert_match(/unknown colouring "sepia"/, response.body)
  end

  # Item 6: Studio's logo is solid colour, so it has no original: its pages show Alt, with Original disabled, and say so.
  test "Studio shows Alt only, on every tab, and says it has no original" do
    [{}, { type: "icon" }, { type: "stacked" }, { colouring: "original" }].each do |params|
      get logo_brand_path("studio", params)
      assert_response :success, params.inspect
      assert_select "[data-test='no-original']", { count: 1, text: "McRitchie Studio's logo is solid colour, so it has no separate original." }, params.inspect
      assert_select "[data-test='colouring-option'][data-colouring='original'][aria-disabled='true']", 1
      assert_select "a[data-test='colouring-option'][data-colouring='original']", 0
      assert_select "a[data-test='colouring-option'][data-colouring='alt'][aria-current='true']", 1
      srcs.each { |src| assert_equal named(src, nil), query(src)["colouring"], "#{params.inspect}: Alt: #{src}" }
    end
    get logo_brand_path("studio", colouring: "original")
    assert_equal "original", query(css_select("[data-test='logo-tab']").first["href"])["colouring"], "the ask is carried on to the next brand"
    get logo_brand_path("welding")
    assert_select "[data-test='no-original']", 0
  end

  # Item 9 (Alex, 13:11): "The goal of the logo modification is to set the defaults." A saved kit choice is the tab's
  # default; URL params override it for exploring; the page says which it shows.
  def save(brand, **choice) = BrandKit.for(brand).save_choice(choice.delete(:type), ActionController::Parameters.new(choice), by: "alex@test.com")
  def state = css_select("[data-test='kit-default-state']").first

  test "a saved kit choice is the tab's default: the bare tab opens on it and says so" do
    save("welding", type: :stacked, form: "tagline", text: "first", colouring: "alt", ending_colour: "D7602E")
    get logo_brand_path("welding", type: "stacked")
    assert_equal ["tagline"], css_select("[data-test='form-option'][aria-current='true']").map { |option| option["data-form"] }
    assert_equal ["alt"], css_select("[data-test='colouring-option'][aria-current='true']").map { |option| option["data-colouring"] }
    srcs.each { |src| assert_equal %w[tagline D7602E], query(src).values_at("form", "ending_colour"), src }
    assert_equal "shown", state["data-state"]
    assert_equal "Showing the kit default.", state.text.squish
    assert_equal ["first"], css_select("[data-test='kit-default-text']").map { |badge| badge.ancestors("[data-test='logo-example']").first["data-text"] }
    assert_select "input[data-test='kit-save-default'][disabled]", 1, "already the default"
    # Links leave the defaults out, so the next tab reads its own saved choice.
    tabs = css_select("[data-test='logo-tab']").map { |a| a["href"] }
    assert_equal [logo_brand_path("welding", type: "icon"), logo_brand_path("welding"), logo_brand_path("welding", type: "stacked")], tabs
  end

  test "a param overrides the kit default, the page says so, and Back to kit default is the bare tab" do
    save("welding", type: :stacked, form: "tagline", text: "first")
    get logo_brand_path("welding", type: "stacked", form: "two_line", guides: 1)
    assert_equal ["two_line"], css_select("[data-test='form-option'][aria-current='true']").map { |option| option["data-form"] }
    assert_equal "changed", state["data-state"]
    assert_match(/Changed from the kit default · Back to kit default/, state.text.squish)
    assert_equal logo_brand_path("welding", type: "stacked", guides: 1), css_select("[data-test='kit-default-back']").first["href"]
    assert_select "[data-test='kit-default-text']", 0
    tagline = css_select("[data-test='form-option'][data-form='tagline']").first["href"]
    assert_nil query(tagline)["form"], "the saved form is the default: its link carries no form"
  end

  test "the edit panel's Reset goes back to the kit default's edits, and with none saved to the brand's style" do
    save("industries", type: :navbar, rule: "3", text: "second", colouring: "alt", ending_colour: "C8661F")
    get logo_brand_path("industries")
    assert_equal "shown", state["data-state"]
    srcs.each { |src| assert_equal "C8661F", query(src)["ending_colour"], src }
    get logo_brand_path("industries", ending_colour: "E07B2E")
    assert_equal "changed", state["data-state"]
    reset = css_select("[data-test='edit-reset']").first["href"]
    assert_equal logo_brand_path("industries"), reset, "no edit param: the kit default's edits"
    get reset
    srcs.each { |src| assert_equal "C8661F", query(src)["ending_colour"], src }

    get logo_brand_path("studio", first_colour: "635BB2")
    assert_equal "none", state["data-state"]
    assert_equal logo_brand_path("studio"), css_select("[data-test='edit-reset']").first["href"]
  end

  test "Save as default sits in the tab's control row and saves the tab as shown" do
    get logo_brand_path("welding", type: "stacked", form: "tagline")
    assert_equal "none", state["data-state"]
    form = css_select("[data-test='logo-controls'] form[data-test='kit-save-default-form']").first
    fields = form.css("input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
    assert_equal({ "type" => "stacked", "form" => "tagline", "colouring" => "original", "text" => "first", "return" => "top" },
                 fields.except("_method", "authenticity_token"))
    patch form["action"], params: fields
    assert_redirected_to logo_brand_path("welding", type: "stacked")
    follow_redirect!
    assert_equal ["tagline"], css_select("[data-test='form-option'][aria-current='true']").map { |option| option["data-form"] }
    assert_equal "shown", state["data-state"]
  end
end
