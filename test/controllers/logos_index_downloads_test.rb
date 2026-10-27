# frozen_string_literal: true

require "test_helper"

# [component] /logos downloads (task logos-index-download-formats): each row's Download Navbar, Stacked and Icon links
# sit in the brand column; the page header's Download format toggle (PNG, SVG, JPEG; PNG unless ?download_format=)
# sets every row's links; every link's href is the logo's SVG download, so the page downloads SVG with JavaScript off.
# And the regression for Commercial Welding v2: a saved Navbar or Stacked choice is drawn on the index exactly as its
# brand page draws it, the icon included, when the kit has no icon of its own.
class LogosIndexDownloadsTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def query(src) = Rack::Utils.parse_query(URI(src).query.to_s)
  def row(brand) = "[data-test='logo-brand-row'][data-brand='#{brand}']"

  # The index's sample images of one type for a brand, by tone.
  def index_srcs(brand, type)
    css_select("[data-test='logo-cluster'][data-brand='#{brand}'] [data-test='logo-sample'][data-type='#{type}'] img")
      .to_h { |img| [query(img["src"])["tone"], img["src"]] }
  end

  def page_srcs = css_select("[data-test='logo-type'] img[data-test='logo-image']").to_h { |img| [query(img["src"])["tone"], img["src"]] }

  test "each row's three downloads sit in the brand column, one per tone, and each downloads the logo's SVG" do
    get logos_path
    assert_select "#{row('welding_v2')} td [data-test='logo-sample-download']", 0, "no downloads left under the cluster"
    links = css_select("#{row('welding_v2')} th [data-test='logo-downloads'] [data-test='logo-sample-download']")
    assert_equal %w[navbar navbar stacked stacked icon icon], links.map { |a| a["data-type"] }
    assert_equal ["Download Navbar", "Download Stacked", "Download Icon"], links.map { |a| a.text.strip }.uniq
    assert_equal %w[light dark] * 3, links.map { |a| query(a["href"])["tone"] }

    links.each do |link|
      assert_equal "1", query(link["href"])["download"], "the href is the SVG download: what a page with JavaScript off gets"
      assert_equal link["href"].sub(/[?&]download=1/, "").sub("&download=1", ""), link["data-svg"].sub(/[?&]download=1/, ""), "the raster is drawn from the same logo"
      assert_match(/\.svg\z/, link["data-filename"])
      assert_equal Logos::PngSizes::BACKGROUNDS.fetch(query(link["href"])["tone"].to_sym), link["data-background"]
    end
    assert_equal({ "navbar" => "width:800", "stacked" => "width:800", "icon" => "long:512" },
                 links.to_h { |a| [a["data-type"], a["data-raster-size"]] }, "each type's Logos::PngSizes default preset")

    # The Icon download is the row's one icon, exactly as its tile shows it.
    icon_tile = index_srcs("welding_v2", "icon")
    links.select { |a| a["data-type"] == "icon" }.each do |link|
      assert_equal icon_tile.fetch(query(link["href"])["tone"]), link["data-svg"]
    end

    get links.find { |a| a["data-type"] == "icon" }["href"]
    assert_equal "image/svg+xml", response.media_type
    assert_equal "attachment", response.headers["Content-Disposition"][/\A\w+/]
  end

  test "the format toggle opens on PNG, and ?download_format= sets every row's links and survives navigation" do
    get logos_path
    assert_select "[data-test='download-format-control'][hidden]", 1, "served hidden: with JavaScript off every link is an SVG, so no PNG is offered"
    assert_select "[data-test='download-format-control'] [data-test='download-format-option']", 3
    assert_equal %w[PNG SVG JPEG], css_select("[data-test='download-format-option']").map { |a| a.text.strip }
    assert_select "[data-test='download-format-option'][aria-current='true']", "PNG"
    assert_select "[data-test='logo-brands'][data-download-format='png']"
    png = css_select("[data-test='download-format-option']").find { |a| a.text.strip == "PNG" }
    assert_nil query(png["href"])["download_format"], "the default drops the param"

    jpeg = css_select("[data-test='download-format-option']").find { |a| a.text.strip == "JPEG" }
    assert_equal "jpeg", query(jpeg["href"])["download_format"]
    get jpeg["href"]
    assert_select "[data-test='download-format-option'][aria-current='true']", "JPEG"
    assert_select "[data-test='logo-brands'][data-download-format='jpeg']"
    # Every other control and the brand links carry it.
    css_select("[data-test='colouring-option'], #{row('industries')} th > a, #{row('industries')} [data-test='logo-sample']").each do |link|
      assert_equal "jpeg", query(link["href"])["download_format"], link.to_s
    end
    assert_select "[data-test='context-form'] input[type=hidden][name='download_format'][value='jpeg']"
    # ...and the brand page's links back to the table keep it.
    get logo_brand_path("industries", download_format: "jpeg")
    assert_response :success
    assert(css_select("a[href^='/logos?'], a[href='/logos']").any? { |a| query(a["href"])["download_format"] == "jpeg" }, "a link back to /logos keeps the format")

    get logos_path(download_format: "gif")
    assert_response :unprocessable_content
  end

  # REGRESSION (Commercial Welding v2, 2026-10-27): with a Stacked choice saved in Alt with edits and no kit icon, the
  # index drew the brand's Original helmet beside the saved Alt words (…-icon-original-custom.svg), while the brand
  # page, the /stacked route and the kit export draw the choice as saved: the Alt helmet (…-custom.svg).
  test "a saved Stacked or Navbar choice draws on the index exactly as on its brand page, its icon included" do
    kit = BrandKit.for("welding_v2")
    kit.save_choice(:stacked, ActionController::Parameters.new(form: "tagline", text: "first", colouring: "alt",
                                                               first_colour: "D7602E", ending_colour: "D7602E"), by: "alex@test.com")
    kit.save_choice(:navbar, ActionController::Parameters.new(rule: "4", text: "second", colouring: "alt", first_colour: "D7602E"), by: "alex@test.com")

    { "stacked" => { type: "stacked" }, "navbar" => {} }.each do |type, page|
      get logos_path
      index = index_srcs("welding_v2", type)
      download = css_select("#{row('welding_v2')} [data-test='logo-sample-download'][data-type='#{type}']").to_h { |a| [query(a["href"])["tone"], a["data-filename"]] }
      get logo_brand_path("welding_v2", page)
      assert_equal page_srcs, index, "#{type}: the index draws the saved choice as its brand page does"
      assert_nil query(index.fetch("dark"))["icon_colouring"], "#{type}: the saved choice's own (Alt) helmet, not the brand's Original"
      assert_equal "welding_v2-stacked-tagline-first-dark-custom.svg", download.fetch("dark") if type == "stacked"
    end

    # With a kit icon saved, both draw the kit's icon.
    kit.save_choice(:icon, ActionController::Parameters.new(colouring: "original"), by: "alex@test.com")
    get logos_path
    index = index_srcs("welding_v2", "stacked")
    get logo_brand_path("welding_v2", type: "stacked")
    assert_equal page_srcs, index
    assert_equal "original", query(index.fetch("dark"))["icon_colouring"]
  end
end
