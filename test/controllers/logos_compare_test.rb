# frozen_string_literal: true

require "test_helper"

# [component] THE KIT COMPARE through the routes (task logo-compare-and-original-edits): the Compare buttons on /logos
# and on a brand page, two brand dropdowns, each side's kit default with its name and kit status above it, the shared
# controls (Context, Colouring, type tabs, Rule or Form) carried by every other control, the Show grid toggle drawing
# both sides' construction guides at one scale, downloads per side, and the 404 and 422 for what it does not know.
class LogosCompareTest < ActionDispatch::IntegrationTest
  BY = "alex@test.com"

  setup { log_in_as(users(:alex)) }

  def query(href) = Rack::Utils.parse_query(URI(href).query.to_s)
  def sides = css_select("[data-test='compare-side']")
  def side_images(side) = side.css("img[data-test='logo-image']")
  def href(test) = css_select("[data-test='#{test}']").first["href"]

  test "the Compare buttons open Commercial Welding v1 against v2, and a brand against its other version" do
    get logos_path
    assert_equal({ "left" => "welding", "right" => "welding_v2" }, query(href("compare-link")))
    assert_equal logos_compare_path, URI(href("compare-link")).path

    get logo_brand_path("welding_v2", type: "stacked")
    assert_equal({ "left" => "welding_v2", "right" => "welding", "type" => "stacked" }, query(href("compare-link")))
    get logo_brand_path("studio")
    assert_equal({ "left" => "studio", "right" => "industries" }, query(href("compare-link")))
  end

  test "each side draws its brand's kit default with its name and kit status above it" do
    BrandKit.for("welding_v2").save_choice(:stacked, ActionController::Parameters.new(form: "tagline", text: "second", colouring: "original", first_colour: "D7602E"), by: BY)
    get logos_compare_path(left: "welding", right: "welding_v2", type: "stacked")
    assert_response :success
    assert_select "h1", "Compare kits"
    assert_equal %w[welding welding_v2], sides.map { |side| side["data-brand"] }
    left, right = sides
    assert_equal "Commercial Welding v1", left.at_css("[data-test='compare-brand-link']").text.strip
    assert_equal "Kit: not saved yet", left.at_css("[data-test='compare-kit-status']").text.strip
    assert_match(/Kit: saved \w{3} \d+, \d{4}/, right.at_css("[data-test='compare-kit-status']").text)
    assert_equal "false", left.at_css("[data-test='compare-source']")["data-saved"]
    assert_match(/\ABrand style \(no Stacked Logo saved\): two lines, first word leads, original colouring/, left.at_css("[data-test='compare-source']").text.strip)
    assert_match(/\AKit default: with tagline, second word leads, original colouring, first word Spark Orange/, right.at_css("[data-test='compare-source']").text.strip)
    right_srcs = side_images(right).map { |img| query(img["src"]) }
    assert_equal 2, right_srcs.size, "a light and a dark version"
    right_srcs.each do |src|
      assert_equal %w[tagline second original D7602E], src.values_at("form", "text", "colouring", "first_colour")
    end
    assert_select "[data-test='compare-brand'][data-side='left'] option[selected]", "Commercial Welding v1"
    assert_select "[data-test='compare-brand'][data-side='right'] option[selected]", "Commercial Welding v2"
    assert_equal 2, sides.sum { |side| side.css("[data-test='logo-download']").size } / 2, "a download pair per side"
  end

  test "the shared controls change both sides, and every control keeps the others" do
    get logos_compare_path(left: "welding", right: "welding_v2", rule: 3, colouring: "alt")
    sides.each do |side|
      side_images(side).each { |img| assert_equal %w[3 second], query(img["src"]).values_at("rule", "text") }
      assert_match(/rule and colouring from the controls above/, side.at_css("[data-test='compare-source']").text)
    end
    tab = css_select("[data-test='logo-tab'][data-type='stacked']").first["href"]
    assert_equal({ "left" => "welding", "right" => "welding_v2", "type" => "stacked", "rule" => "3", "colouring" => "alt" }, query(tab))
    assert_equal({ "left" => "welding", "right" => "welding_v2", "colouring" => "alt" }, query(css_select("[data-test='rule-option'][data-rule='kit']").first["href"]))
    assert_equal({ "left" => "welding_v2", "right" => "welding", "rule" => "3", "colouring" => "alt" }, query(href("compare-swap")))
    hidden = css_select("form[data-test='compare-brands-form'] input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
    assert_equal({ "rule" => "3", "colouring" => "alt" }, hidden)
    context = css_select("form[data-test='context-form'] input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
    assert_equal({ "left" => "welding", "right" => "welding_v2", "rule" => "3", "colouring" => "alt" }, context)

    get logos_compare_path(left: "turf", right: "welding", type: "stacked", form: "tagline")
    assert_select "[data-test='form-option']", 4, "Kit default and the three forms either side draws"
    assert_select "[data-test='compare-side'][data-brand='turf'] [data-test='compare-note']", /Turf Monster has no with tagline form/
  end

  test "Show grid draws both sides' construction guides at one scale" do
    get logos_compare_path(left: "welding", right: "welding_v2", type: "stacked")
    assert_select "[data-test='grid-toggle']", "Show grid"
    assert_equal "1", query(href("grid-toggle"))["grid"]

    # The tagline form: v1's name carries LLC, so its drawing is the wider (the two-line forms are the same width).
    get logos_compare_path(left: "welding", right: "welding_v2", type: "stacked", form: "tagline", grid: 1)
    assert_select "[data-test='compare'][data-grid='1']"
    assert_select "[data-test='grid-toggle'][aria-pressed='true']", "Hide grid"
    assert_select "[data-test='grid-sentence']"
    shares = sides.map do |side|
      side_images(side).map do |img|
        assert_equal "1", query(img["src"])["guides"]
        img["data-share"].to_f
      end
    end
    assert_equal [1.0], shares.flatten.max(1), "the wider drawing fills its frame"
    assert_in_delta 3059.62 / 3521.28, shares.last.first, 1e-3, "v2's narrower drawing takes its share of the frame, so both are at one scale"

    get logos_compare_path(left: "welding", right: "welding_v2", type: "icon", grid: 1)
    assert_select "[data-test='grid-toggle']", 0, "the icon has no construction guides"
  end

  test "an unknown brand is a 404 and an unknown control a plain-text 422" do
    get logos_compare_path(left: "acme", right: "welding")
    assert_response :not_found
    get logos_compare_path(left: "welding", right: "welding_v2", rule: "5")
    assert_response :unprocessable_content
    assert_match(/unknown rule "5"/, response.body)
    get logos_compare_path(type: "logo")
    assert_response :unprocessable_content
    get logos_compare_path(grid: "yes")
    assert_response :unprocessable_content
  end

  test "watermark draws one watermark version per side" do
    get logos_compare_path(left: "welding", right: "welding_v2", context: "watermark")
    sides.each { |side| side_images(side).each { |img| assert_equal "watermark", query(img["src"])["tone"] } }
  end
end
