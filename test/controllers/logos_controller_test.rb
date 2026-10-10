# frozen_string_literal: true

require "test_helper"

# [component] /logos through the routes: admin only on every action, the index
# row per brand with one logo of each type (icon, Navbar Logo, Stacked Logo),
# the brand page's rules, texts, plates, guides toggle, download and copy, and
# the three SVG endpoints' headers and refusals. Each logo shows once, in the
# context ?context= names.
class LogosControllerTest < ActionDispatch::IntegrationTest
  LABEL = "McRitchie Industries navbar logo, rule of 4, second word leads, light"
  PLATES = { "light" => "background-color: #FFFFFF", "dark" => "background-color: #12141A",
             "watermark" => "background-image: linear-gradient(135deg, #263B5C, #2C625E)" }.freeze
  SAMPLES = { "icon" => [{}, "icon"], "navbar" => [{ rule: 4, text: "second" }, "navbar logo, rule of 4, second word leads"],
              "stacked" => [{ text: "first" }, "stacked logo, first word leads"] }.freeze

  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  def requests
    { index: -> { get logos_path }, show: -> { get logo_brand_path("industries") },
      icon: -> { get icon_logo_path("industries", tone: "dark") },
      navbar: -> { get navbar_logo_path("industries", rule: 4, text: "second") },
      stacked: -> { get stacked_logo_path("industries", text: "first") } }
  end

  # The sample of one type the index shows for a brand: [its SVG route, its accessible name].
  def sample(brand, name, type, context)
    params, words = SAMPLES.fetch(type)
    guides = type == "icon" ? {} : { guides: 0 }
    [public_send(:"#{type}_logo_path", brand, params.merge(tone: context, **guides)), "#{name} #{words}, #{context}"]
  end

  test "every routed action is refused to a visitor and to a signed-in non-admin" do
    routed = Rails.application.routes.routes.select { |r| r.defaults[:controller] == "logos" }.map { |r| (r.defaults[:type] || r.defaults[:action]).to_sym }
    assert_equal routed.uniq.sort, requests.keys.sort, "every routed action, and every type of the asset route, is covered here"

    [nil, @viewer].each do |user|
      log_in_as(user) if user
      requests.each do |action, request|
        request.call
        assert_response :redirect, "#{action} did not turn #{user ? 'a non-admin' : 'a visitor'} away"
        assert_no_match(/<svg|navbar logo|stacked logo|Industries icon/, response.body.to_s, "#{action} leaked a logo")
      end
    end
  end

  test "the index lists each brand with one logo of each type, on the light plate, its typeface and its colours" do
    log_in_as(@admin)
    get logos_path
    assert_response :success

    assert_equal ["Brand", "Icon", "Navbar Logo", "Stacked Logo", "Typeface", "Colours"], css_select("[data-test='logo-brands'] thead th").map { |th| th.text.strip }
    assert_equal Logos::NavbarLogo.brands, css_select("[data-test='logo-brand-row']").map { |row| row["data-brand"] }
    assert_select "[data-test='logo-table-scroll'].overflow-x-auto [data-test='logo-brands']", 1, "a wide row scrolls inside its own container"
    assert_select "[data-test='logo-brand-row'][data-brand='industries']" do
      assert_select "th a[href=?]", logo_brand_path("industries"), text: "McRitchie Industries"
      assert_equal %w[icon navbar stacked], css_select("[data-brand='industries'] [data-test='logo-sample']").map { |cell| cell["data-type"] }
      SAMPLES.each_key do |type|
        src, alt = sample("industries", "McRitchie Industries", type, "light")
        assert_select "[data-test='logo-sample'][data-type='#{type}']" do
          assert_select "a[href=?] [data-test='logo-plate'][data-tone='light'][style*='#FFFFFF'] img[alt=?][src=?]",
                        logo_brand_path("industries", { type: (type unless type == "navbar") }.compact), alt, src
          assert_select "[data-test='logo-plate']", 1
          assert_select "[data-test='logo-image']", 1
          assert_select "p", Logos::Variant::TYPES.fetch(type.to_sym), "the cell names its type where the header row is hidden"
        end
      end
      assert_equal LABEL, sample("industries", "McRitchie Industries", "navbar", "light").last
      assert_select "[data-test='logo-plate']", 3
      assert_select "[data-test='logo-typeface']", /Montserrat\s+weights 700 and 300/
    end
    assert_equal({ "icon" => "max-height: 48px", "navbar" => "max-height: 28px", "stacked" => "max-height: 96px" },
                 css_select("[data-brand='studio'] [data-test='logo-sample']").to_h { |cell| [cell["data-type"], cell.at_css("img")["style"]] })
    swatches = ->(brand) { css_select("[data-brand='#{brand}'] [data-test='logo-swatch']").map { |swatch| swatch.text.strip } }
    assert_equal %w[#262A30 #41464D #8C939C #F4F5F7 #D3D6DA #FFFFFF #FFFFFF], swatches.("industries")
    assert_equal %w[#1A1535 #FFFFFF #8E82FE #FFFFFF], swatches.("studio")
    assert_select "[data-brand='industries'] [data-test='logo-swatch'] span[style='background-color: #8C939C']", 1
    assert_select "[data-test='logo-brand-row'][data-brand='studio'] [data-test='logo-typeface']", /weights 800 and 300/
    assert_select "[data-test='read-only-note']", /Choosing one for a brand comes later/
  end

  test "a brand that cannot be stacked keeps its row: the Stacked cell says why, and the rest of the table is drawn" do
    log_in_as(@admin)
    shipped = Logos::Variant.method(:logo)
    reason = "brand turf: the second word \"Monster\" cannot be tracked out to 60% of the first word's width (it is 68% already): " \
             "set `stacked: one_line` in the brand's style"
    Logos::Variant.define_singleton_method(:logo) do |brand, type = :navbar|
      raise Logos::NavbarLogo::Error, reason if brand == "turf" && type == :stacked

      shipped.call(brand, type)
    end
    begin
      get logos_path(context: "dark")
    ensure
      Logos::Variant.define_singleton_method(:logo, shipped)
    end
    assert_response :success

    assert_equal Logos::NavbarLogo.brands, css_select("[data-test='logo-brand-row']").map { |row| row["data-brand"] }
    assert_select "[data-brand='turf'] [data-test='logo-sample'][data-type='stacked']" do
      assert_select "[data-test='logo-sample-refused']", "Not drawn. #{reason}"
      assert_select "img, a, [data-test='logo-plate']", 0
      assert_select "p", "Stacked Logo"
    end
    assert_select "[data-brand='turf'] [data-test='logo-image']", 2, "its icon and its navbar logo are still shown"
    assert_select "[data-test='logo-sample-refused']", 1
    assert_select "[data-test='logo-image']", 3 * Logos::NavbarLogo.brands.size - 1
    assert_select "[data-brand='turf'] [data-test='logo-colours'] [data-test='logo-swatch']", 11

    get logos_path
    assert_select "[data-test='logo-sample-refused']", 0, "and the shipped brands all stack"
    assert_select "[data-test='logo-image']", 3 * Logos::NavbarLogo.brands.size
  end

  test "the Colours column lists the watermark's fill and opacity after light and dark" do
    log_in_as(@admin)
    get logos_path
    Logos::NavbarLogo.brands.each do |brand|
      assert_equal %w[light dark watermark], css_select("[data-brand='#{brand}'] [data-test='logo-colour-row']").map { |row| row["data-tone"] }, brand
      assert_select "[data-brand='#{brand}'] [data-test='logo-colour-row'][data-tone='watermark']" do
        assert_select "[data-test='logo-swatch']", { count: 1, text: "#FFFFFF" }
        assert_select "[data-test='logo-swatch'] span[style='background-color: #FFFFFF']", 1
        assert_select "[data-test='logo-watermark-opacity']", "at 60% opacity"
        assert_select "span.w-20.shrink-0[data-test='logo-colour-tone']", "watermark", "the label's box is wide enough for the longest tone"
      end
      assert_select "[data-brand='#{brand}'] [data-test='logo-watermark-opacity']", 1
    end
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
        assert_select "th a[href=?]", logo_brand_path(brand), text: name
        SAMPLES.each_key do |type|
          src, alt = sample(brand, name, type, "light")
          assert_select "[data-test='logo-sample'][data-type='#{type}'] [data-test='logo-plate'][data-tone='light'] img[alt=?][src=?]", alt, src
        end
      end
    end
    swatches = ->(brand) { css_select("[data-brand='#{brand}'] [data-test='logo-swatch']").map { |swatch| swatch.text.strip } }
    assert_equal %w[#1A1535 #4BAF50 #1A550D #5C972A #F0EBCF #FFFFFF #4BAF50 #1A550D #5C972A #F0EBCF #FFFFFF], swatches.("turf")
    assert_equal %w[#2D5E8E #D7602E #FFFFFF #F08A5A #FFFFFF], swatches.("welding")
  end

  test "the admin tools list links to the page" do
    log_in_as(@admin)
    get logos_path
    assert_select "a[href=?]", logos_path, text: /Logos/
  end

  # What a brand page's logo images, downloads and copy payloads must be for a list of variants.
  def assert_examples(variants)
    assert_select "[data-test='logo-example']", variants.size
    assert_equal variants.map(&:label), css_select("img[data-test='logo-image']").map { |img| img["alt"] }, "each image names its type, text and context"
    assert_equal variants.map { |v| public_send(:"#{v.type}_logo_path", v.logo.brand, v.params) }, css_select("img[data-test='logo-image']").map { |img| img["src"] }
    assert_equal variants.map { |v| public_send(:"#{v.type}_logo_path", v.logo.brand, v.params.merge(download: 1)) },
                 css_select("a[data-test='logo-download']").map { |link| link["href"] }
    assert_equal variants.map { |v| "Download: #{v.label}" }, css_select("a[data-test='logo-download']").map { |link| link["aria-label"] }
    assert_equal variants.map(&:svg), css_select("button[data-test='logo-copy']").map { |button| button["data-clip"] }, "copy gives the logo as shown"
    assert_equal variants.map { |v| "Copy SVG: #{v.label}" }, css_select("button[data-test='logo-copy']").map { |button| button["aria-label"] }
  end

  def variants(brand, type, **choices) = Logos::Variant.all(Logos::Variant.logo(brand, type), type:, **choices)

  test "a brand page opens on the Navbar Logo tab at the rule of 4: three text versions, each with a download and a copy" do
    log_in_as(@admin)
    get logo_brand_path("industries")
    assert_response :success

    assert_select "[data-test='logo-type'][data-type='navbar']", 1
    assert_select "[data-test='logo-rule']", 0, "the two rule sections are gone: the Rule control picks one"
    assert_equal %w[homogeneous first second], css_select("[data-test='logo-example']").map { |example| example["data-text"] }
    assert_equal ["Homogeneous", "First word leads", "Second word leads"], css_select("[data-test='logo-example'] h2").map { |h| h.text.strip }
    assert_examples variants("industries", :navbar, rule: 4)
    assert_select "img[data-test='logo-image'][alt=?][src=?]", LABEL, navbar_logo_path("industries", rule: 4, text: "second", tone: "light", guides: 0)
    assert_select "[data-test='logo-plate'][data-tone='light'][style=?]", PLATES.fetch("light"), 3
    assert_select "[data-test='type-sentence']", { count: 1, text: /\AThe icon is four rows tall.*the middle two rows\.\z/ }
    assert_select "[data-test='guides-sentence']", 0
    assert_select "[data-test='transparent-note']", /Every logo file has a transparent background/
    assert_select "[data-test='watermark-note']", 0
    assert_includes response.body, "window.copyText"
    # Every control on the page has the page's own focus ring: the tabs, the Rule options, the guides toggle, Download and Copy SVG.
    ringed = css_select(".btn").select { |control| control["class"].include?("focus-visible:outline-[#4338CA]! dark:focus-visible:outline-white!") }
    assert_equal %w[logo-tab logo-tab logo-tab rule-option rule-option guides-toggle] + %w[logo-download logo-copy] * 3, ringed.map { |control| control["data-test"] }
    assert_select "[data-test='read-only-note']", /Choosing one for the brand comes later/
    assert_select "[data-test='brand-note']", /drawn flat.*without the marketing kit's steel gradient and tick marks/
  end

  test "the tabs are links by logo type, and the current one says so" do
    log_in_as(@admin)
    { nil => "navbar", "navbar" => "navbar", "icon" => "icon", "stacked" => "stacked" }.each do |param, current|
      get logo_brand_path("industries", { type: param }.compact)
      assert_response :success
      assert_select "nav[aria-label='Logo type'][data-test='logo-tabs']", 1 do
        assert_equal [["icon", "Icon", logo_brand_path("industries", type: "icon")], ["navbar", "Navbar Logo", logo_brand_path("industries")],
                      ["stacked", "Stacked Logo", logo_brand_path("industries", type: "stacked")]],
                     css_select("a[data-test='logo-tab']").map { |tab| [tab["data-type"], tab.text.strip, tab["href"]] }
        assert_equal [current], css_select("a[data-test='logo-tab'][aria-current='page']").map { |tab| tab["data-type"] }
        assert_select "a[data-test='logo-tab'].btn", 3, "a .btn carries the focus ring"
        assert_select "a[data-test='logo-tab'][aria-current='page'].btn-primary.border.border-transparent", 1, "the chosen tab is the same box as the others"
        assert_select "a[data-test='logo-tab'].btn-neutral:not(.border-transparent)", 2
      end
      assert_select "[data-test='logo-type'][data-type='#{current}']", 1
    end
  end

  test "the Rule control shows one rule at a time, with its sentence" do
    log_in_as(@admin)
    { nil => 4, "4" => 4, "3" => 3 }.each do |param, rule|
      get logo_brand_path("studio", { rule: param }.compact)
      assert_response :success
      assert_select "[data-test='rule-control'][role='group'][aria-label='Rule']", 1
      assert_equal [["3", "Rule of 3", logo_brand_path("studio", rule: 3)], ["4", "Rule of 4", logo_brand_path("studio")]],
                   css_select("a[data-test='rule-option']").map { |option| [option["data-rule"], option.text.strip, option["href"]] }
      assert_equal [rule.to_s], css_select("a[data-test='rule-option'][aria-current='true']").map { |option| option["data-rule"] }
      assert_select "a[data-test='rule-option'][aria-current='true'].btn-primary.border.border-transparent", 1
      assert_examples variants("studio", :navbar, rule:)
      assert_select "img[data-test='logo-image'][alt*='rule of #{rule}']", 3
      assert_select "[data-test='type-sentence']", { count: 1, text: Logos::Variant::RULE_SENTENCES.fetch(rule) }
    end
    %w[icon stacked].each do |type|
      get logo_brand_path("studio", type:, rule: 3)
      assert_select "[data-test='rule-control']", 0, "only the Navbar Logo has a rule"
    end
  end

  test "the Stacked Logo tab shows the three text versions, states the 3-2-1 method, and names the brand's form" do
    log_in_as(@admin)
    { "industries" => /This brand uses the two-line form\.\z/, "welding" => /two-line form/,
      "turf" => /This brand uses the one-line form, because its second word is too wide to sit under its first/ }.each do |brand, form|
      get logo_brand_path(brand, type: "stacked")
      assert_response :success
      assert_equal %w[homogeneous first second], css_select("[data-test='logo-example']").map { |example| example["data-text"] }
      assert_examples variants(brand, :stacked)
      assert_select "img[data-test='logo-image'][alt*=' stacked logo, '][src^=?]", stacked_logo_path(brand), 3
      assert_select "[data-test='type-sentence']", { count: 1, text: /\AThe 3-2-1 method: .*3 units tall, every gap is 2 units.*1 unit tall.*60% of the big word's width/ }
      assert_select "[data-test='type-sentence']", form
      assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path(brand, type: "stacked", guides: 1), text: "Show guides"

      get logo_brand_path(brand, type: "stacked", guides: 1)
      assert_response :success
      assert_examples variants(brand, :stacked, guides: true)
      assert_select "img[data-test='logo-image'][alt$='construction guides'][src*='guides=1']", 3
      assert_equal 3, css_select("button[data-test='logo-copy']").count { |button| button["data-clip"].include?(">2u</text>") }
      assert_select "[data-test='guides-sentence']", brand == "turf" ? /a bracket for the icon's height/ : /the small word turned on its side beside the icon/
      assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path(brand, type: "stacked"), text: "Hide guides"
    end
  end

  test "the Icon tab shows the icon alone with a download and a copy, and no rule or guides" do
    log_in_as(@admin)
    PLATES.each do |context, plate|
      get logo_brand_path("welding", type: "icon", context:, guides: 1, rule: 3)
      assert_response :success
      assert_examples variants("welding", :icon, tone: context.to_sym)
      assert_select "img[data-test='logo-image'][alt=?][src=?]", "Commercial Welding icon, #{context}", icon_logo_path("welding", tone: context)
      assert_select "a[data-test='logo-download'][href=?]", icon_logo_path("welding", tone: context, download: 1)
      assert_select "[data-test='logo-plate'][data-tone='#{context}'][style=?]", plate, 1
      assert_select "[data-test='logo-example'] h2", 0
      assert_select "[data-test='guides-toggle'], [data-test='rule-control'], [data-test='logo-controls'], [data-test='guides-sentence']", 0
      assert_select "[data-test='type-sentence']", "The icon alone, as this brand's logos draw it."
      assert_select "[data-test='watermark-text-note']", 0, "an icon has no text versions to compare"
    end
  end

  test "every control keeps every other control's setting, and the breadcrumb keeps the context" do
    log_in_as(@admin)
    get logo_brand_path("turf", type: "stacked", context: "watermark", rule: 3, guides: 1)
    assert_response :success
    kept = { context: "watermark", rule: 3, guides: 1 }
    assert_equal [logo_brand_path("turf", kept.merge(type: "icon")), logo_brand_path("turf", kept), logo_brand_path("turf", kept.merge(type: "stacked"))],
                 css_select("a[data-test='logo-tab']").map { |tab| tab["href"] }
    assert_select "form[data-test='context-form'][action=?]", logo_brand_path("turf") do
      assert_equal [%w[type stacked], %w[rule 3], %w[guides 1]], css_select("form[data-test='context-form'] input[type='hidden']").map { |i| [i["name"], i["value"]] }
      assert_select "select#logo-context option[selected][value='watermark']", 1
    end
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf", type: "stacked", context: "watermark", rule: 3), text: "Hide guides"
    assert_select "a[data-test='logos-crumb'][href=?]", logos_path(context: "watermark"), text: "Logos"

    get logo_brand_path("turf", context: "dark", guides: 1)
    assert_equal [logo_brand_path("turf", context: "dark", rule: 3, guides: 1), logo_brand_path("turf", context: "dark", guides: 1)],
                 css_select("a[data-test='rule-option']").map { |option| option["href"] }
    assert_equal [%w[guides 1]], css_select("form[data-test='context-form'] input[type='hidden']").map { |i| [i["name"], i["value"]] }
    assert_select "a[data-test='logos-crumb'][href=?]", logos_path(context: "dark")
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf", context: "dark"), text: "Hide guides"

    # The defaults (Navbar Logo, light, rule of 4, guides off) are left out, even when named.
    get logo_brand_path("turf", type: "navbar", context: "light", rule: 4, guides: 0)
    assert_response :success
    assert_select "a[data-test='logo-tab'][data-type='navbar'][href=?]", logo_brand_path("turf")
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf", guides: 1), text: "Show guides"
    assert_select "form[data-test='context-form'] input[type='hidden']", 0
    assert_select "a[data-test='logos-crumb'][href=?]", logos_path
  end

  test "a brand with no note in its style shows none" do
    log_in_as(@admin)
    get logo_brand_path("studio")
    assert_response :success
    assert_select "h1", "McRitchie Studio"
    assert_select "[data-test='brand-note']", 0
  end

  test "each added brand's page says how its art was derived on every tab" do
    log_in_as(@admin)
    notes = {
      "turf" => ["Turf Monster", "The head is auto-traced from the 880 px picture, with its grass texture flattened to three solid colours."],
      "welding" => ["Commercial Welding", "The helmet and the lettering are auto-traced from the current PNG files. The name is drawn without “LLC” and the " \
                                          "service mark. On dark backgrounds the helmet is the single-colour version."]
    }
    notes.to_a.product(%w[icon navbar stacked]).each do |(brand, (name, note)), type|
      get logo_brand_path(brand, type:)
      assert_response :success
      assert_select "h1", name
      assert_equal [note], css_select("[data-test='brand-note']").map { |p| p.text.strip }
      alts = css_select("[data-test='logo-image']").map { |img| img["alt"] }
      assert_equal type == "icon" ? 1 : 3, alts.uniq.size
      assert alts.all? { |alt| alt.start_with?("#{name} #{Logos::Variant::TYPES.fetch(type.to_sym).downcase}, ") }, alts.inspect
    end
  end

  test "the context dropdown offers light, dark and watermark, and each switches every logo on every tab" do
    log_in_as(@admin)
    PLATES.to_a.product(%w[icon navbar stacked]).each do |(context, plate), type|
      get logo_brand_path("industries", type:, context:)
      assert_response :success

      assert_select "form[data-test='context-form'][method='get'][action=?]", logo_brand_path("industries"), 1 do
        assert_select "label[for='logo-context']", "Context"
        assert_select "select#logo-context[name='context'][onchange*='requestSubmit']", 1
        assert_equal [%w[light Light], %w[dark Dark], %w[watermark Watermark]], css_select("select#logo-context option").map { |o| [o["value"], o.text] }
        assert_equal [context], css_select("select#logo-context option[selected]").map { |o| o["value"] }
        assert_select "noscript input[type='submit'][value='Apply']", 1, "the form works with JavaScript off"
        assert_select "input[type='submit']", 1, "and with JavaScript on there is no button: the dropdown submits on change"
        assert_select "input[name='guides']", 0
      end
      shown = variants("industries", type.to_sym, tone: context.to_sym)
      assert_examples shown
      assert_select "[data-test='logo-example'][data-tone='#{context}'] [data-test='logo-plate'][data-tone='#{context}'][style=?]", plate, shown.size
      assert_select "img[data-test='logo-image'][src*='tone=#{context}'][alt$=', #{context}']", shown.size
      assert_select "a[data-test='logo-download'][href*='tone=#{context}'][href*='download=1']", shown.size
    end
  end

  test "the watermark context says what a watermark is, and that a colour-led brand's texts look the same" do
    log_in_as(@admin)
    { "turf" => 1, "welding" => 1, "studio" => 0, "industries" => 0 }.each do |brand, same|
      %w[navbar stacked].each do |type|
        get logo_brand_path(brand, type:, context: "watermark")
        assert_response :success
        assert_select "[data-test='watermark-note']", /whole logo in one colour, slightly transparent/
        assert_select "[data-test='watermark-text-note']", same
        assert_select "[data-test='logo-example']", 3, "no version is hidden"
        assert_select "[data-test='transparent-note']", 1
      end

      get logo_brand_path(brand, context: "dark")
      assert_select "[data-test='watermark-note']", 0
    end
    assert_select "[data-test='watermark-text-note']", 0
  end

  test "the index shows one logo of each type per brand in the chosen context, and its links carry the context" do
    log_in_as(@admin)
    PLATES.each do |context, plate|
      get logos_path(context:)
      assert_response :success
      carried = context == "light" ? {} : { context: }

      assert_select "form[data-test='context-form'][method='get'][action=?]", logos_path, 1
      assert_select "form[data-test='context-form'] noscript input[type='submit'][value='Apply']", 1
      assert_select "form[data-test='context-form'] > input[type='submit']", 0
      assert_equal [context], css_select("select#logo-context option[selected]").map { |o| o["value"] }
      assert_select "[data-test='logo-plate']", 3 * Logos::NavbarLogo.brands.size
      assert_select "[data-test='logo-image']", 3 * Logos::NavbarLogo.brands.size
      Logos::NavbarLogo.brands.each do |brand|
        name = Logos::Variant.brand_name(Logos::NavbarLogo.new(brand))
        assert_select "[data-test='logo-brand-row'][data-brand='#{brand}']" do
          assert_select "[data-test='logo-plate'][data-tone='#{context}'][style=?]", plate, 3
          assert_select "a[href=?]", logo_brand_path(brand, carried), 2, "the name and the navbar logo open the default tab"
          SAMPLES.each_key do |type|
            src, alt = sample(brand, name, type, context)
            assert_select "a[href=?][aria-label=?] img[data-test='logo-image'][alt=?][src=?]",
                          logo_brand_path(brand, { type: (type unless type == "navbar") }.compact.merge(carried)),
                          "#{name}: #{Logos::Variant::TYPES.fetch(type.to_sym).downcase}", alt, src
          end
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
    assert_select "a[data-test='guides-toggle'].btn-neutral[href=?]", logo_brand_path("industries", guides: 1), text: "Show guides"
    assert_select "img[data-test='logo-image'][src*='guides=1']", 0

    get logo_brand_path("industries", guides: 1, rule: 3)
    assert_response :success
    assert_select "a[data-test='guides-toggle'].btn-primary[href=?]", logo_brand_path("industries", rule: 3), text: "Hide guides"
    assert_examples variants("industries", :navbar, rule: 3, guides: true)
    assert_select "img[data-test='logo-image'][src*='guides=1'][alt$='construction guides']", 3
    assert_select "a[data-test='logo-download'][href*='guides=1']", 3
    assert_equal 3, css_select("button[data-test='logo-copy']").count { |button| button["data-clip"].include?("<line") }
    assert_select "[data-test='guides-sentence']", /the numbered rows, the icon's right edge and where the name starts\.\s+They are for looking at, never for shipping\. A drawing never shrinks below a readable size: where one is wider than its plate, scroll it sideways\./

    # A guide drawing fits its plate (max-width) down to a least width of its own, where its plate starts to scroll.
    assert_select "[data-test='logo-plate'].overflow-x-auto[role='group'][aria-label^='Guide drawing: McRitchie Industries navbar logo']", 3
    # A tab stop as served (so it works with JavaScript off); the script drops the tabindex wherever the drawing fits.
    assert_select "[data-test='logo-plate'][tabindex='0'][x-init*='scrollWidth > $el.clientWidth'][x-init*='removeAttribute'][x-init*='ResizeObserver']", 3
    styles = css_select("[data-test='logo-plate'] img.max-w-full").map { |img| img["style"] }
    assert_equal 3, styles.size
    styles.each { |style| assert_match(/\Amax-height: 132px; min-width: [5-6]\d\dpx\z/, style) }
    get logo_brand_path("industries", type: "stacked", guides: 1)
    assert_equal ["max-height: 380px; min-width: 335px", "max-height: 380px; min-width: 335px", "max-height: 380px; min-width: 323px"],
                 css_select("[data-test='logo-plate'].overflow-x-auto img.max-w-full").map { |img| img["style"] }
    get logo_brand_path("industries", type: "stacked")
    assert_select "[data-test='logo-plate'].overflow-x-auto, [data-test='logo-plate'][tabindex]", 0
    assert_select "[data-test='logo-plate'] img[style='max-height: 240px'].max-w-full", 3
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

  test "icon serves the brand's icon alone in the tone asked for, named by brand and tone" do
    log_in_as(@admin)
    logo = Logos::NavbarLogo.new("industries")
    get icon_logo_path("industries", tone: "dark")
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal logo.icon_svg(tone: :dark), response.body
    assert_match(/\Ainline; filename="industries-icon-dark\.svg"/, response.headers["Content-Disposition"])

    get icon_logo_path("industries", download: 1)
    assert_equal logo.icon_svg(tone: :light), response.body
    assert_match(/\Aattachment; filename="industries-icon-light\.svg"/, response.headers["Content-Disposition"])

    # An icon has a tone and nothing else: the other types' choices are not read, so they cannot be wrong.
    get icon_logo_path("welding", tone: "watermark", rule: 9, text: "third", guides: "yes")
    assert_response :success
    assert_equal Logos::NavbarLogo.new("welding").icon_svg(tone: :watermark), response.body
    assert_match(/filename="welding-icon-watermark\.svg"/, response.headers["Content-Disposition"])
  end

  test "stacked serves the stacked logo, its guide drawing, and a named file with download=1" do
    log_in_as(@admin)
    logo = Logos::StackedLogo.new("industries")
    get stacked_logo_path("industries", text: "first", tone: "light", guides: 0)
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal logo.svg(text: :first, tone: :light), response.body
    assert_match(/\Ainline; filename="industries-stacked-first-light\.svg"/, response.headers["Content-Disposition"])
    assert_no_match(/<text|<line/, response.body)

    get stacked_logo_path("industries", tone: "dark", guides: 1, download: 1, rule: 9)
    assert_response :success, "a stacked logo has no rule, so the param is not read"
    assert_equal logo.svg(tone: :dark, guides: true), response.body
    assert_match(/\Aattachment; filename="industries-stacked-homogeneous-dark-guides\.svg"/, response.headers["Content-Disposition"])
    assert_equal %w[2u 3u 2u 1u], Nokogiri::XML(response.body).remove_namespaces!.css("text").map(&:text)

    get stacked_logo_path("turf", text: "second", tone: "watermark")
    assert_equal Logos::StackedLogo.new("turf").svg(text: :second, tone: :watermark), response.body
    assert_match(/filename="turf-stacked-second-watermark\.svg"/, response.headers["Content-Disposition"])
  end

  test "an asset route's type is its own: a type in the query string cannot change it" do
    log_in_as(@admin)
    get "/logos/industries/navbar?type=icon&rule=4&text=second"
    assert_response :success
    assert_equal Logos::NavbarLogo.new("industries").svg(rule: 4, text: :second), response.body
    get "/logos/industries/icon?type=sepia"
    assert_response :success
    assert_equal Logos::NavbarLogo.new("industries").icon_svg, response.body
    get "/logos/industries/sepia"
    assert_response :not_found
  end

  test "an unknown brand is a 404 on the page and on the endpoint" do
    log_in_as(@admin)
    [logo_brand_path("acme"), navbar_logo_path("acme"), navbar_logo_path("acme", rule: 9), icon_logo_path("acme"),
     stacked_logo_path("acme", text: "third")].each do |path|
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

    { icon_logo_path("industries", tone: "sepia") => /unknown tone "sepia"/, icon_logo_path("industries", download: "yes") => /unknown download "yes"/,
      stacked_logo_path("industries", text: "third") => /unknown text "third"/, stacked_logo_path("industries", guides: "2") => /unknown guides "2"/,
      stacked_logo_path("industries", tone: %w[dark]) => /unknown tone/ }.each do |path, message|
      get path
      assert_response :unprocessable_content, path
      assert_equal "text/plain", response.media_type
      assert_match message, response.body
      assert_no_match(/stacked_logo\.rb|variant\.rb|backtrace/i, response.body)
    end

    get logo_brand_path("industries", guides: "maybe")
    assert_response :unprocessable_content
    assert_match(/unknown guides "maybe"/, response.body)

    { logo_brand_path("industries", type: "submark") => /unknown type "submark": expected one of icon, navbar, stacked/,
      logo_brand_path("industries", type: "") => /unknown type ""/, logo_brand_path("industries", rule: 5) => /unknown rule "5": expected one of 3, 4/,
      logo_brand_path("industries", type: "icon", rule: "four") => /unknown rule "four"/,
      logo_brand_path("industries", type: "icon", guides: "yes") => /unknown guides "yes"/ }.each do |path, message|
      get path
      assert_response :unprocessable_content, path
      assert_equal "text/plain", response.media_type
      assert_match message, response.body
    end

    [logo_brand_path("industries", context: "clearspace"), logos_path(context: "clearspace"), logos_path(context: ""),
     logo_brand_path("industries", context: %w[dark])].each do |path|
      get path
      assert_response :unprocessable_content, path
      assert_equal "text/plain", response.media_type
      assert_match(/unknown context .*: expected one of light, dark, watermark/, response.body)
    end
  end
end
