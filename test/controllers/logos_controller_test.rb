# frozen_string_literal: true

require "test_helper"

# [component] /logos through the routes: admin only on every action, the index
# row per brand, the brand page's rules, texts, plates, guides toggle, download
# and copy, and the SVG endpoint's headers and refusals.
class LogosControllerTest < ActionDispatch::IntegrationTest
  LABEL = "McRitchie Industries navbar logo, rule of 4, second word leads, light"

  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  def requests
    { index: -> { get logos_path }, show: -> { get logo_path("industries") },
      navbar: -> { get navbar_logo_path("industries", rule: 4, text: "second") } }
  end

  test "every routed action is refused to a visitor and to a signed-in non-admin" do
    routed = Rails.application.routes.routes.filter_map { |r| r.defaults[:action] if r.defaults[:controller] == "logos" }
    assert_equal routed.map(&:to_sym).uniq.sort, requests.keys.sort, "every routed action is covered here"

    [nil, @viewer].each do |user|
      log_in_as(user) if user
      requests.each do |action, request|
        request.call
        assert_response :redirect, "#{action} did not turn #{user ? 'a non-admin' : 'a visitor'} away"
        assert_no_match(/<svg|navbar logo/, response.body.to_s, "#{action} leaked a logo")
      end
    end
  end

  test "the index lists each brand with its rule-of-4 logo on both plates, its typeface and its colours" do
    log_in_as(@admin)
    get logos_path
    assert_response :success

    assert_equal Logos::NavbarLogo.brands, css_select("[data-test='logo-brand-row']").map { |row| row["data-brand"] }
    assert_select "[data-test='logo-brand-row'][data-brand='industries']" do
      assert_select "a[href=?]", logo_path("industries"), text: "McRitchie Industries"
      assert_select "[data-test='logo-plate'][data-tone='light'][style*='#FFFFFF'] img[alt=?][src=?]", LABEL,
                    navbar_logo_path("industries", rule: 4, text: "second", tone: "light", guides: 0)
      assert_select "[data-test='logo-plate'][data-tone='dark'][style*='#12141A'] img[alt=?]", LABEL.sub("light", "dark")
      assert_select "[data-test='logo-typeface']", /Montserrat\s+weights 700 and 300/
    end
    swatches = ->(brand) { css_select("[data-brand='#{brand}'] [data-test='logo-swatch']").map { |swatch| swatch.text.strip } }
    assert_equal %w[#262A30 #41464D #8C939C #F4F5F7 #D3D6DA #FFFFFF], swatches.("industries")
    assert_equal %w[#1A1535 #FFFFFF #8E82FE], swatches.("studio")
    assert_select "[data-brand='industries'] [data-test='logo-swatch'] span[style='background-color: #8C939C']", 1
    assert_select "[data-test='logo-brand-row'][data-brand='studio'] [data-test='logo-typeface']", /weights 800 and 300/
    assert_select "[data-test='read-only-note']", /Choosing one for a brand comes later/
  end

  test "the admin tools list links to the page" do
    log_in_as(@admin)
    get logos_path
    assert_select "a[href=?]", logos_path, text: /Logos/
  end

  test "a brand page shows every rule and text on a light and a dark plate, each with a download and a copy" do
    log_in_as(@admin)
    get logo_path("industries")
    assert_response :success

    assert_equal %w[3 4], css_select("[data-test='logo-rule']").map { |section| section["data-rule"] }
    assert_select "[data-test='logo-rule'][data-rule='3'] [data-test='rule-sentence']", /three rows tall.*the middle row\./
    assert_select "[data-test='logo-rule'][data-rule='4'] [data-test='rule-sentence']", /four rows tall.*the middle two rows\./
    css_select("[data-test='logo-rule']").each do |section|
      assert_equal %w[homogeneous first second], section.css("[data-test='logo-text']").map { |text| text["data-text"] }
      assert_equal ["Homogeneous", "First word leads", "Second word leads"], section.css("h3").map { |h| h.text.strip }
    end
    assert_select "[data-test='logo-example']", 12
    assert_select "[data-test='logo-plate'][data-tone='light'][style*='#FFFFFF']", 6
    assert_select "[data-test='logo-plate'][data-tone='dark'][style*='#12141A']", 6
    assert_equal 12, css_select("[data-test='logo-image']").map { |img| img["alt"] }.uniq.size, "each logo has its own accessible name"

    assert_select "[data-test='logo-rule'][data-rule='4'] [data-test='logo-text'][data-text='second'] [data-test='logo-example'][data-tone='light']" do
      assert_select "img[alt=?][src=?]", LABEL, navbar_logo_path("industries", rule: 4, text: "second", tone: "light", guides: 0)
      assert_select "a[data-test='logo-download'][href=?]",
                    navbar_logo_path("industries", rule: 4, text: "second", tone: "light", guides: 0, download: 1)
      copy = css_select("button[data-test='logo-copy']").find { |button| button["aria-label"] == "Copy SVG: #{LABEL}" }
      assert_equal Logos::NavbarLogo.new("industries").svg(rule: 4, text: :second, tone: :light), copy["data-clip"],
                   "the copy button carries the exact SVG the endpoint serves"
    end
    assert_includes response.body, "window.copyText"
    assert_select "[data-test='read-only-note']", /Choosing one for the brand comes later/
    assert_select "[data-test='brand-note']", /drawn flat.*without the marketing kit's steel gradient and tick marks/
  end

  test "the flat-icon note is Industries' alone" do
    log_in_as(@admin)
    get logo_path("studio")
    assert_response :success
    assert_select "h1", "McRitchie Studio"
    assert_select "[data-test='brand-note']", 0
  end

  test "the guides toggle swaps every logo for its guide drawing and back" do
    log_in_as(@admin)
    get logo_path("industries")
    assert_select "a[data-test='guides-toggle'][href=?]", logo_path("industries", guides: 1), text: "Show guides"
    assert_select "img[data-test='logo-image'][src*='guides=1']", 0

    get logo_path("industries", guides: 1)
    assert_response :success
    assert_select "a[data-test='guides-toggle'][href=?]", logo_path("industries"), text: "Hide guides"
    assert_select "img[data-test='logo-image'][src*='guides=1']", 12
    assert_select "img[data-test='logo-image'][alt$='construction guides']", 12
    assert_select "a[data-test='logo-download'][href*='guides=1']", 12
    assert_equal 12, css_select("button[data-test='logo-copy']").count { |button| button["data-clip"].include?("<line") }
  end

  test "navbar serves the one logo inline, and as a named file with download=1" do
    log_in_as(@admin)
    expected = Logos::NavbarLogo.new("industries").svg(rule: 4, text: :second, tone: :light)

    get navbar_logo_path("industries", rule: 4, text: "second", tone: "light", guides: 0)
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal expected, response.body
    assert_match(/\Ainline; filename="industries-navbar-rule4-second-light\.svg"/, response.headers["Content-Disposition"])

    get navbar_logo_path("industries", rule: 4, text: "second", tone: "light", download: 1)
    assert_equal expected, response.body
    assert_match(/\Aattachment; filename="industries-navbar-rule4-second-light\.svg"/, response.headers["Content-Disposition"])

    get navbar_logo_path("studio", tone: "dark", guides: 1, download: 1)
    assert_equal Logos::NavbarLogo.new("studio").svg(tone: :dark, guides: true), response.body
    assert_match(/\Aattachment; filename="studio-navbar-rule3-homogeneous-dark-guides\.svg"/, response.headers["Content-Disposition"])
  end

  test "an unknown brand is a 404 on the page and on the endpoint" do
    log_in_as(@admin)
    [logo_path("acme"), navbar_logo_path("acme"), navbar_logo_path("acme", rule: 9)].each do |path|
      get path
      assert_response :not_found, path
    end
  end

  test "a bad param is a 422 that names it in plain text, with no trace" do
    log_in_as(@admin)
    { { rule: 5 } => /unknown rule "5"/, { text: "third" } => /unknown text "third"/, { tone: "sepia" } => /unknown tone "sepia"/,
      { guides: "yes" } => /unknown guides "yes"/, { download: "true" } => /unknown download "true"/,
      { rule: %w[4] } => /unknown rule/, { text: %(<script>alert(1)</script>) } => /unknown text/ }.each do |params, message|
      get navbar_logo_path("industries", params)
      assert_response :unprocessable_content, params.inspect
      assert_equal "text/plain", response.media_type, "a refusal is plain text, so nothing in it can run"
      assert_match message, response.body
      assert_no_match(/navbar_logo\.rb|variant\.rb|backtrace/i, response.body)
    end

    get logo_path("industries", guides: "maybe")
    assert_response :unprocessable_content
    assert_match(/unknown guides "maybe"/, response.body)
  end
end
