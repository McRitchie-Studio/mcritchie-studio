# frozen_string_literal: true

require "test_helper"

# [integration] The brand page fetches each logo from its own URL (task logo-gallery-polish-pass, item 10): it carries no
# SVG inline, and each tone's URL answers the very SVG its Download gives, inline. The brand page's Copy SVG went with
# task brand-page-split-layout (one Download button); the PNG drawing fetches the same URL.
class LogosCopyFetchTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def copies = css_select("[data-test='logo-copy']")

  # Each tone's radio carries the URL the PNG is drawn from (data-svg) and the one Download gives (data-download-url).
  test "each tone names its logo's URL, which answers the SVG the Download gives, inline" do
    get logo_brand_path("turf", type: "stacked", form: "one_line", first_colour: "4BAF50")
    assert_equal 0, copies.size, "no Copy SVG on the brand page"
    tones = css_select("input[data-test='download-tone-option']")
    assert_equal %w[dark light watermark], tones.map { |input| input["value"] }
    chosen = css_select("input[data-test='download-tone-option'][checked]")
    assert_equal ["light"], chosen.map { |input| input["value"] }, "the first tone shown, as the logo is"
    assert_equal [chosen.first["data-download-url"]], css_select("[data-test='logo-download']").map { |link| link["href"] }
    tones.map { |input| [input["data-svg"], input["data-download-url"]] }.each do |url, download|
      assert_equal Rack::Utils.parse_query(URI(download).query).except("download"), Rack::Utils.parse_query(URI(url).query), url
      assert_equal URI(download).path, URI(url).path

      get url
      assert_response :success
      assert_equal "image/svg+xml", response.media_type
      assert_equal "inline", response.headers["Content-Disposition"][/\A\w+/]
      svg = response.body
      get download
      assert_equal svg, response.body, "the copy is the download"
    end
  end

  test "the page carries no SVG markup of its own for copying, so it stays small" do
    get logo_brand_path("turf")
    assert_empty css_select("[data-clip]")
    refute_includes response.body, "&lt;svg", "no escaped SVG in an attribute"
    assert_operator response.body.bytesize, :<, 400_000, "was about 1.5 MB with every SVG inline"
  end

  test "a guide drawing's image fetches the guide drawing" do
    get logo_brand_path("industries", guides: 1)
    url = css_select("img[data-test='logo-image']").first["src"]
    assert_equal "1", Rack::Utils.parse_query(URI(url).query)["guides"]
    get url
    assert_includes response.body, "guide-ghosts"
  end
end
