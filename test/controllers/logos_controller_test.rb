# frozen_string_literal: true

require "test_helper"

# [component] /logos through the routes: admin only on every action, the index
# row per brand, the brand page's rules, texts, plates, guides toggle, download
# and copy, and the SVG endpoint's headers and refusals. Each logo shows once,
# in the context ?context= names (task logo-gallery-context-dropdown).
class LogosControllerTest < ActionDispatch::IntegrationTest
  LABEL = "McRitchie Industries navbar logo, rule of 4, second word leads, light"
  PLATES = { "light" => "background-color: #FFFFFF", "dark" => "background-color: #12141A",
             "watermark" => "background-image: linear-gradient(135deg, #3F5E8C, #4F9A94)" }.freeze

  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  def requests
    { index: -> { get logos_path }, show: -> { get logo_brand_path("industries") },
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

  test "the index lists each brand with its rule-of-4 logo once, on the light plate, its typeface and its colours" do
    log_in_as(@admin)
    get logos_path
    assert_response :success

    assert_equal Logos::NavbarLogo.brands, css_select("[data-test='logo-brand-row']").map { |row| row["data-brand"] }
    assert_select "[data-test='logo-brand-row'][data-brand='industries']" do
      assert_select "a[href=?]", logo_brand_path("industries"), text: "McRitchie Industries"
      assert_select "[data-test='logo-plate'][data-tone='light'][style*='#FFFFFF'] img[alt=?][src=?]", LABEL,
                    navbar_logo_path("industries", rule: 4, text: "second", tone: "light", guides: 0)
      assert_select "[data-test='logo-plate']", 1
      assert_select "[data-test='logo-image']", 1
      assert_select "[data-test='logo-typeface']", /Montserrat\s+weights 700 and 300/
    end
    swatches = ->(brand) { css_select("[data-brand='#{brand}'] [data-test='logo-swatch']").map { |swatch| swatch.text.strip } }
    assert_equal %w[#262A30 #41464D #8C939C #F4F5F7 #D3D6DA #FFFFFF], swatches.("industries")
    assert_equal %w[#1A1535 #FFFFFF #8E82FE], swatches.("studio")
    assert_select "[data-brand='industries'] [data-test='logo-swatch'] span[style='background-color: #8C939C']", 1
    assert_select "[data-test='logo-brand-row'][data-brand='studio'] [data-test='logo-typeface']", /weights 800 and 300/
    assert_select "[data-test='read-only-note']", /Choosing one for a brand comes later/
  end

  test "the index lists Turf Monster and Commercial Welding beside the first two, each with a true typeface" do
    log_in_as(@admin)
    get logos_path
    assert_response :success

    assert_equal %w[studio industries turf welding], css_select("[data-test='logo-brand-row']").map { |row| row["data-brand"] }
    typeface = ->(brand) { css_select("[data-brand='#{brand}'] [data-test='logo-typeface']").text.squish }
    assert_equal "Typeface Montserrat weight 800", typeface.("turf")
    assert_equal "Typeface Traced from its own lettering (typeface not identified)", typeface.("welding")
    assert_no_match(/Montserrat/, typeface.("welding"))

    { "turf" => "Turf Monster", "welding" => "Commercial Welding" }.each do |brand, name|
      assert_select "[data-test='logo-brand-row'][data-brand='#{brand}']" do
        assert_select "a[href=?]", logo_brand_path(brand), text: name
        assert_select "[data-test='logo-plate'][data-tone='light'] img[alt=?][src=?]",
                      "#{name} navbar logo, rule of 4, second word leads, light",
                      navbar_logo_path(brand, rule: 4, text: "second", tone: "light", guides: 0)
      end
    end
    swatches = ->(brand) { css_select("[data-brand='#{brand}'] [data-test='logo-swatch']").map { |swatch| swatch.text.strip } }
    assert_equal %w[#1A1535 #4BAF50 #1A550D #5C972A #F0EBCF #FFFFFF #4BAF50 #1A550D #5C972A #F0EBCF], swatches.("turf")
    assert_equal %w[#2D5E8E #D7602E #FFFFFF #F08A5A], swatches.("welding")
  end

  test "the admin tools list links to the page" do
    log_in_as(@admin)
    get logos_path
    assert_select "a[href=?]", logos_path, text: /Logos/
  end

  test "a brand page shows every rule and text once, on the light plate, each with a download and a copy" do
    log_in_as(@admin)
    get logo_brand_path("industries")
    assert_response :success

    assert_equal %w[3 4], css_select("[data-test='logo-rule']").map { |section| section["data-rule"] }
    assert_select "[data-test='logo-rule'][data-rule='3'] [data-test='rule-sentence']", /three rows tall.*the middle row\./
    assert_select "[data-test='logo-rule'][data-rule='4'] [data-test='rule-sentence']", /four rows tall.*the middle two rows\./
    css_select("[data-test='logo-rule']").each do |section|
      assert_equal %w[homogeneous first second], section.css("[data-test='logo-text']").map { |text| text["data-text"] }
      assert_equal ["Homogeneous", "First word leads", "Second word leads"], section.css("h3").map { |h| h.text.strip }
    end
    assert_select "[data-test='logo-example']", 6
    assert_select "[data-test='logo-text'] [data-test='logo-example']", 6
    css_select("[data-test='logo-text']").each { |text| assert_equal 1, text.css("[data-test='logo-image']").size, "one logo per rule and text, not a pair" }
    assert_select "[data-test='logo-plate'][data-tone='light'][style=?]", PLATES.fetch("light"), 6
    assert_equal 6, css_select("[data-test='logo-image']").map { |img| img["alt"] }.uniq.size, "each logo has its own accessible name"
    assert_select "[data-test='transparent-note']", /Every logo file has a transparent background/
    assert_select "[data-test='watermark-note']", 0

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

  test "a brand with no note in its style shows none" do
    log_in_as(@admin)
    get logo_brand_path("studio")
    assert_response :success
    assert_select "h1", "McRitchie Studio"
    assert_select "[data-test='brand-note']", 0
  end

  test "each added brand's page says how its art was derived and shows its six logos by name" do
    log_in_as(@admin)
    notes = {
      "turf" => ["Turf Monster", "The head is auto-traced from the 880 px picture, with its grass texture flattened to three solid colours."],
      "welding" => ["Commercial Welding", "The helmet and the lettering are auto-traced from the current PNG files. The name is drawn without “LLC” and the " \
                                          "service mark. On dark backgrounds the helmet is the single-colour version."]
    }
    notes.each do |brand, (name, note)|
      get logo_brand_path(brand)
      assert_response :success
      assert_select "h1", name
      assert_equal [note], css_select("[data-test='brand-note']").map { |p| p.text.strip }
      assert_select "[data-test='logo-plate'][data-tone='light'][style*='#FFFFFF']", 6
      assert_select "[data-test='logo-plate']", 6
      alts = css_select("[data-test='logo-image']").map { |img| img["alt"] }
      assert_equal 6, alts.uniq.size
      assert alts.all? { |alt| alt.start_with?("#{name} navbar logo, rule of ") }, alts.inspect

      get logo_brand_path(brand, guides: 1)
      assert_response :success
      assert_select "img[data-test='logo-image'][alt$='construction guides']", 6
    end
  end

  test "the context dropdown offers light, dark and watermark, and each switches every logo on the brand page" do
    log_in_as(@admin)
    PLATES.each do |context, plate|
      get logo_brand_path("industries", context:)
      assert_response :success

      assert_select "form[data-test='context-form'][method='get'][action=?]", logo_brand_path("industries"), 1 do
        assert_select "label[for='logo-context']", "Context"
        assert_select "select#logo-context[name='context'][onchange*='requestSubmit']", 1
        assert_equal [%w[light Light], %w[dark Dark], %w[watermark Watermark]], css_select("select#logo-context option").map { |o| [o["value"], o.text] }
        assert_equal [context], css_select("select#logo-context option[selected]").map { |o| o["value"] }
        assert_select "input[type='submit'][value='Apply']", 1, "the form works with JavaScript off"
        assert_select "input[name='guides']", 0
      end
      assert_select "[data-test='logo-example']", 6
      assert_select "[data-test='logo-example'][data-tone='#{context}'] [data-test='logo-plate'][data-tone='#{context}'][style=?]", plate, 6
      assert_select "img[data-test='logo-image'][src*='tone=#{context}'][alt$=', #{context}']", 6
      assert_select "a[data-test='logo-download'][href*='tone=#{context}'][href*='download=1']", 6
      expected = Logos::Variant.all(Logos::NavbarLogo.new("industries"), tone: context.to_sym).map(&:svg)
      assert_equal expected, css_select("button[data-test='logo-copy']").map { |button| button["data-clip"] }, "copy gives the logo as shown"
    end
  end

  test "the context and the guides survive each other's toggle" do
    log_in_as(@admin)
    get logo_brand_path("turf", context: "watermark", guides: 1)
    assert_response :success
    assert_select "form[data-test='context-form'] input[type='hidden'][name='guides'][value='1']", 1
    assert_select "select#logo-context option[selected][value='watermark']", 1
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf", context: "watermark"), text: "Hide guides"
    assert_select "img[data-test='logo-image'][src*='tone=watermark'][src*='guides=1'][alt$='watermark, construction guides']", 6
    assert_select "a[data-test='logo-download'][href*='tone=watermark'][href*='guides=1']", 6

    get logo_brand_path("turf", context: "dark")
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf", context: "dark", guides: 1), text: "Show guides"
    assert_select "form[data-test='context-form'] input[name='guides']", 0

    # An explicit light is the default: it is not carried on.
    get logo_brand_path("turf", context: "light", guides: 1)
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf"), text: "Hide guides"
  end

  test "the watermark context says what a watermark is, and that a colour-led brand's texts look the same" do
    log_in_as(@admin)
    { "turf" => 1, "welding" => 1, "studio" => 0, "industries" => 0 }.each do |brand, same|
      get logo_brand_path(brand, context: "watermark")
      assert_response :success
      assert_select "[data-test='watermark-note']", /whole logo in one colour, slightly transparent/
      assert_select "[data-test='watermark-text-note']", same
      assert_select "[data-test='logo-text']", 6, "no row is hidden"
      assert_select "[data-test='transparent-note']", 1

      get logo_brand_path(brand, context: "dark")
      assert_select "[data-test='watermark-note']", 0
    end
    assert_select "[data-test='watermark-text-note']", 0
  end

  test "the index shows one logo per brand in the chosen context, and its links carry the context" do
    log_in_as(@admin)
    PLATES.each do |context, plate|
      get logos_path(context:)
      assert_response :success
      carried = context == "light" ? {} : { context: }

      assert_select "form[data-test='context-form'][method='get'][action=?]", logos_path, 1
      assert_equal [context], css_select("select#logo-context option[selected]").map { |o| o["value"] }
      assert_select "[data-test='logo-plate']", Logos::NavbarLogo.brands.size
      assert_select "[data-test='logo-image']", Logos::NavbarLogo.brands.size
      Logos::NavbarLogo.brands.each do |brand|
        assert_select "[data-test='logo-brand-row'][data-brand='#{brand}']" do
          assert_select "[data-test='logo-plate'][data-tone='#{context}'][style=?]", plate, 1
          assert_select "img[data-test='logo-image'][alt$=', #{context}'][src=?]", navbar_logo_path(brand, rule: 4, text: "second", tone: context, guides: 0)
          assert_select "a[href=?]", logo_brand_path(brand, carried), 2
        end
      end
      assert_select "[data-test='transparent-note']", 1
      assert_select "[data-test='watermark-note']", context == "watermark" ? 1 : 0
      assert_select "[data-test='watermark-text-note']", 0
    end
  end

  test "the endpoint serves the watermark as one fill in one translucent group, named -watermark.svg" do
    log_in_as(@admin)
    get navbar_logo_path("turf", rule: 4, text: "second", tone: "watermark", download: 1)
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal Logos::NavbarLogo.new("turf").svg(rule: 4, text: :second, tone: :watermark), response.body
    assert_match(/\Aattachment; filename="turf-navbar-rule4-second-watermark\.svg"/, response.headers["Content-Disposition"])

    xml = Nokogiri::XML(response.body).remove_namespaces!
    assert_equal [["g", "0.6"]], xml.root.element_children.map { |node| [node.name, node["opacity"]] }
    assert_equal ["#FFFFFF"], xml.css("path").map { |path| path["fill"] }.uniq
    assert_equal Logos::NavbarLogo.icons.fetch("turf_mono").fetch("layers").map { |layer| layer["d"] },
                 xml.css("path:not([transform])").map { |path| path["d"] }, "the linework head, not the three solid layers"
  end

  test "Commercial Welding is served in its own lettering, with the single-colour helmet on dark" do
    log_in_as(@admin)
    lettering = Logos::NavbarLogo.letterings.fetch("welding").fetch("words").values.flatten.map { |letter| letter["d"] }
    icons = Logos::NavbarLogo.icons
    { "light" => "welding", "dark" => "welding_mono" }.each do |tone, icon|
      get navbar_logo_path("welding", rule: 4, text: "second", tone:)
      assert_response :success
      assert_equal "image/svg+xml", response.media_type
      paths = Nokogiri::XML(response.body).remove_namespaces!.css("path")
      icon_paths, letters = paths.partition { |path| path["transform"].nil? }
      assert_equal lettering, letters.map { |path| path["d"] }, tone
      assert_equal ["evenodd"], letters.map { |path| path["fill-rule"] }.uniq
      assert_equal icons.fetch(icon).fetch("layers").map { |layer| layer["d"] }, icon_paths.map { |path| path["d"] }, tone
    end
    assert_match(/filename="welding-navbar-rule4-second-dark\.svg"/, response.headers["Content-Disposition"])
  end

  test "the guides toggle swaps every logo for its guide drawing and back" do
    log_in_as(@admin)
    get logo_brand_path("industries")
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("industries", guides: 1), text: "Show guides"
    assert_select "img[data-test='logo-image'][src*='guides=1']", 0

    get logo_brand_path("industries", guides: 1)
    assert_response :success
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("industries"), text: "Hide guides"
    assert_select "img[data-test='logo-image'][src*='guides=1']", 6
    assert_select "img[data-test='logo-image'][alt$='construction guides']", 6
    assert_select "a[data-test='logo-download'][href*='guides=1']", 6
    assert_equal 6, css_select("button[data-test='logo-copy']").count { |button| button["data-clip"].include?("<line") }
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
    [logo_brand_path("acme"), navbar_logo_path("acme"), navbar_logo_path("acme", rule: 9)].each do |path|
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

    get logo_brand_path("industries", guides: "maybe")
    assert_response :unprocessable_content
    assert_match(/unknown guides "maybe"/, response.body)

    [logo_brand_path("industries", context: "clearspace"), logos_path(context: "clearspace"), logos_path(context: ""),
     logo_brand_path("industries", context: %w[dark])].each do |path|
      get path
      assert_response :unprocessable_content, path
      assert_equal "text/plain", response.media_type
      assert_match(/unknown context .*: expected one of light, dark, watermark/, response.body)
    end
  end
end
