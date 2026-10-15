# frozen_string_literal: true

require "test_helper"

# [integration] Copy SVG fetches the logo from its own URL (task logo-gallery-polish-pass, item 10): the brand page
# carries no SVG for its copy buttons, and each button's URL answers the very SVG its Download gives, inline.
class LogosCopyFetchTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def copies = css_select("[data-test='logo-copy']")

  # Task logo-download-card: one Copy SVG on the Download card, pointed at the tone picked; each tone's radio carries
  # the URL Copy SVG fetches (data-svg) and the one Download gives (data-download-url).
  test "each Copy SVG names its logo's URL, which answers the SVG the Download gives, inline" do
    get logo_brand_path("turf", type: "stacked", form: "one_line", first_colour: "4BAF50")
    assert_equal 1, copies.size, "one logo, one Copy SVG"
    refute copies.first.key?("data-clip"), "no SVG inline"
    tones = css_select("input[data-test='download-tone-option']")
    assert_equal %w[light dark watermark], tones.map { |input| input["value"] }
    assert_equal tones.first["data-svg"], copies.first["data-copy-svg"], "Copy SVG starts on the first tone"
    assert_equal [tones.first["data-download-url"]], css_select("[data-test='logo-download']").map { |link| link["href"] }
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

  test "a guide drawing's copy fetches the guide drawing" do
    get logo_brand_path("industries", guides: 1)
    url = copies.first["data-copy-svg"]
    assert_equal "1", Rack::Utils.parse_query(URI(url).query)["guides"]
    get url
    assert_includes response.body, "guide-ghosts"
  end
end
