# frozen_string_literal: true

require "test_helper"

# [component] /logos through the routes: admin only on every action, the index
# row per brand with one logo of each type (icon, Navbar Logo, Stacked Logo),
# the brand page's rules, texts, guides toggle, download and copy, and the three
# SVG endpoints' headers and refusals. Task brand-gallery-palette-and-theme: no
# plates; each logo is rendered in its light and dark versions and the hub theme
# shows one (CSS on html.dark), or in its watermark version under
# ?context=watermark, which also turns the page dark.
class LogosControllerTest < ActionDispatch::IntegrationTest
  LABEL = "McRitchie Industries navbar logo, rule of 4, second word leads, light"
  CONTEXTS = %w[light dark watermark].freeze
  SAMPLES = { "icon" => [{}, "icon"], "navbar" => [{ rule: 4, text: "second" }, "navbar logo, rule of 4, second word leads"],
              "stacked" => [{ text: "first" }, "stacked logo, %<form>s, first word leads"] }.freeze
  # The index's stacked sample is each brand's own form.
  OWN_FORMS = { "studio" => "two_line", "industries" => "two_line", "turf" => "one_line", "welding" => "two_line" }.freeze

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
    if type == "stacked"
      params = params.merge(form: OWN_FORMS.fetch(brand))
      words = format(words, form: Logos::Variant::FORMS.fetch(OWN_FORMS.fetch(brand).to_sym).downcase)
    end
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

  test "the index shows each brand's logos as one tight cluster: stacked square, navbar beside it, icon under the navbar" do
    log_in_as(@admin)
    get logos_path
    assert_response :success

    assert_equal %w[Brand Logos Typeface Colours], css_select("[data-test='logo-brands'] thead th").map { |th| th.text.strip }
    assert_equal Logos::NavbarLogo.brands, css_select("[data-test='logo-brand-row']").map { |row| row["data-brand"] }
    assert_select "[data-test='logo-table-scroll'].overflow-x-auto [data-test='logo-brands']", 1, "a wide row scrolls inside its own container"
    assert_select "[data-test='logo-cluster']", Logos::NavbarLogo.brands.size, "one cluster per brand"
    assert_select "[data-test='logo-brand-row'][data-brand='industries']" do
      assert_select "th a[href=?]", logo_brand_path("industries"), text: "McRitchie Industries"
      assert_select "[data-test='logo-cell'] p", "Logos", "the cell names itself where the header row is hidden"
      assert_select "[data-test='logo-cell'] > [data-test='logo-cluster'].rounded-2xl.flex-wrap", 1
      # The square on the left; the navbar logo, then the icon, stacked in the column beside it.
      assert_select "[data-test='logo-cluster'] > [data-test='logo-sample'][data-type='stacked'].w-\\[7\\.375rem\\].h-\\[7\\.375rem\\]", 1
      assert_select "[data-test='logo-cluster'] > div.flex-col > [data-test='logo-sample']", 2
      assert_equal %w[stacked navbar icon], css_select("[data-brand='industries'] [data-test='logo-sample']").map { |cell| cell["data-type"] }
      assert_equal %w[navbar icon], css_select("[data-brand='industries'] [data-test='logo-cluster'] > div.flex-col > [data-test='logo-sample']").map { |c| c["data-type"] }
      assert_select "[data-test='logo-sample'][data-type='icon'].h-14.w-14", 1, "the icon is a small square"
      assert_select "[data-test='logo-sample'][data-type='navbar'].h-14", 1, "as tall as the icon: the two make the square's height"
      SAMPLES.each_key do |type|
        src, alt = sample("industries", "McRitchie Industries", type, "light")
        assert_select "a[data-test='logo-sample'][data-type='#{type}'][href=?]", logo_brand_path("industries", { type: (type unless type == "navbar") }.compact) do
          assert_select "[data-test='logo-badge']", LogosHelper::LOGO_BADGES.fetch(type.to_sym)
          assert_select "img[data-test='logo-image'][alt=?][src=?]", alt, src
        end
      end
      assert_equal LABEL, sample("industries", "McRitchie Industries", "navbar", "light").last
      assert_select "[data-test='logo-plate']", 0, "no plate: the logos sit on the page's own background"
    end
    assert_equal %w[Stacked Navbar Icon], css_select("[data-brand='studio'] [data-test='logo-badge']").map { |badge| badge.text.strip }
    assert_equal({ "stacked" => "max-height: 88px", "navbar" => "max-height: 28px", "icon" => "max-height: 28px" },
                 css_select("[data-brand='studio'] [data-test='logo-sample']").to_h { |cell| [cell["data-type"], cell.at_css("img")["style"]] })
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
      assert_select "[data-test='logo-badge']", "Stacked", "the tile still names its type"
    end
    assert_select "[data-brand='turf'] [data-test='logo-cluster'] > div[data-test='logo-sample'][data-type='stacked']", 1, "it keeps its place in the cluster"
    assert_select "[data-brand='turf'] [data-test='logo-image']", 4, "its icon and its navbar logo are still shown, light and dark"
    assert_select "[data-test='logo-sample-refused']", 1
    assert_select "[data-test='logo-image']", 2 * (3 * Logos::NavbarLogo.brands.size - 1)
    assert_select "[data-brand='turf'] [data-test='logo-colours'] [data-test='logo-swatch']", 7

    get logos_path
    assert_select "[data-test='logo-sample-refused']", 0, "and the shipped brands all stack"
    assert_select "[data-test='logo-image']", 2 * 3 * Logos::NavbarLogo.brands.size
  end

  # The palettes Alex chose (epic brand-studio, 2026-10-10 22:45), in order, as config/logo_brands.yml lists them.
  PALETTES = {
    "studio" => [["Ink", "#1A1535"], ["Violet", "#8E82FE"], ["Deep Violet", "#635BB2"], ["Violet Mist", "#EEECFF"], ["White", "#FFFFFF"]],
    "industries" => [["Forge Orange", "#C8661F"], ["Ember Orange", "#E07B2E"], ["Charcoal Steel", "#262A30"], ["Gunmetal", "#59606A"],
                     ["Brushed Steel", "#8C939C"], ["Light Steel", "#D3D6DA"], ["Shop Black", "#141516"], ["White", "#FFFFFF"]],
    "turf" => [["Brand Green", "#4BAF50"], ["Forest", "#2E7D32"], ["Deep Green", "#1A550D"], ["Grass", "#5C972A"], ["Cream", "#F0EBCF"],
               ["Ink", "#1A1535"], ["Violet", "#8E82FE"]],
    "welding" => [["Welding Blue", "#2D5E8E"], ["Spark Orange", "#D7602E"], ["Ember", "#F08A5A"], ["White", "#FFFFFF"]]
  }.freeze

  def palette_shown(scope)
    css_select("#{scope} [data-test='logo-swatch']").map do |swatch|
      [swatch.at_css("[data-test='logo-swatch-name']").text.strip, swatch.at_css("[data-test='logo-swatch-hex']").text.strip]
    end
  end

  test "the Colours column shows each brand's one named palette, and nothing about light, dark or watermark" do
    log_in_as(@admin)
    get logos_path
    PALETTES.each do |brand, palette|
      assert_equal palette, palette_shown("[data-brand='#{brand}'] [data-test='logo-colours']"), brand
      palette.each do |name, hex|
        assert_select "[data-brand='#{brand}'] [data-test='logo-swatch'][data-hex='#{hex}']" do
          assert_select "[data-test='logo-swatch-chip'][style=?]", "background-color: #{hex}"
          assert_select "button[data-test='logo-swatch-copy'][aria-label=?]", "Copy #{name} #{hex}"
        end
        copy = css_select("[data-brand='#{brand}'] [data-test='logo-swatch'][data-hex='#{hex}'] button").first
        assert_equal hex, copy["data-copy-hex"], "a click copies the hex (app/javascript/logo_gallery.js)"
        assert_select "[data-brand='#{brand}'] [data-test='logo-swatch'][data-hex='#{hex}']" do
        end
      end
    end
    assert_select "[data-test='logo-colours']" do
      assert_select "[data-test='logo-colour-row'], [data-test='logo-colour-tone'], [data-test='logo-watermark-opacity']", 0
    end
    assert_no_match(/opacity/, css_select("[data-test='logo-colours']").text)
    assert_select "script", /window\.copyText = window\.copyText/, "the page carries the copy helper the swatches call"
  end

  test "a brand page shows the brand's palette as named swatches, on every tab and in every context" do
    log_in_as(@admin)
    %w[icon navbar stacked].product(%w[light dark watermark]).each do |type, context|
      get logo_brand_path("industries", type:, context:)
      assert_response :success
      assert_select "section[data-test='brand-colours'] h2", "Colours"
      assert_equal PALETTES.fetch("industries"), palette_shown("[data-test='brand-colours']"), "#{type} #{context}"
    end
  end

  # The typeface hierarchies Alex asked for (at most three levels, the most prominent first), as [role, name shown].
  HIERARCHIES = {
    "studio" => [["Display", "Montserrat ExtraBold", 800], ["Text", "Montserrat Light", 300], ["Tagline", "Montserrat Medium", 500]],
    "industries" => [["Display", "Montserrat Bold", 700], ["Text", "Montserrat Light", 300], ["Tagline", "Montserrat Medium", 500]],
    "turf" => [["Display", "Montserrat ExtraBold", 800], ["Text", "Montserrat Medium", 500]],
    "welding" => [["Display", "Traced lettering (face not identified)", nil], ["Tagline", "Montserrat Medium", 500]]
  }.freeze

  def hierarchy_shown(scope)
    css_select("#{scope} [data-test='logo-typeface-level']").map do |level|
      [level.at_css("[data-test='logo-typeface-role']").text.strip, level.at_css("[data-test='logo-typeface-name']").text.strip]
    end
  end

  # Each level's name is set in its own face, at a size that steps down with the level: [weight, px] per level.
  def faces_shown(scope)
    css_select("#{scope} [data-test='logo-typeface-level']").map do |level|
      style = level.at_css("[data-test='logo-typeface-name']")["style"].to_s
      [style[/font-weight: (\d+)/, 1]&.to_i, style[/font-size: (\d+)px/, 1]&.to_i, style.include?("font-family: 'Montserrat'") || nil]
    end
  end

  test "the Typeface column shows each brand's hierarchy, each level's name in its own face, stepping down in size" do
    log_in_as(@admin)
    get logos_path
    HIERARCHIES.each do |brand, levels|
      scope = "[data-brand='#{brand}'] [data-test='logo-typeface']"
      assert_equal levels.map { |role, name, _| [role, name] }, hierarchy_shown(scope), brand
      assert_equal (1..levels.size).map(&:to_s), css_select("#{scope} [data-test='logo-typeface-level']").map { |l| l["data-level"] }
      levels.each_with_index do |(_, _, weight), index|
        next unless weight

        assert_equal [weight, LogosHelper::LOGO_TYPEFACE_SIZES.fetch(true)[index], true], faces_shown(scope)[index], "#{brand} level #{index + 1}"
      end
    end
    assert_equal [17, 13, 11], LogosHelper::LOGO_TYPEFACE_SIZES.fetch(true), "each level smaller than the one above"
  end

  test "a traced level shows the brand's name in its own lettering, not a font name in some other face" do
    log_in_as(@admin)
    get logos_path
    assert_select "[data-brand='welding'] [data-test='logo-typeface-level'][data-level='1']" do
      assert_select "[data-test='logo-typeface-traced'] img[data-test='logo-typeface-sample']", 2
      assert_select "[data-test='logo-themed'][data-tone='light'].dark\\:hidden img[src=?][alt=?]",
                    navbar_logo_path("welding", rule: 4, text: "homogeneous", tone: "light", guides: 0),
                    "Commercial Welding navbar logo, rule of 4, homogeneous, light"
      assert_select "[data-test='logo-themed'][data-tone='dark'].hidden img[src=?]",
                    navbar_logo_path("welding", rule: 4, text: "homogeneous", tone: "dark", guides: 0)
      assert_select "[data-test='logo-typeface-name'][style]", 0, "no font is claimed for traced lettering"
    end
    assert_select "[data-test='logo-typeface-traced']", 1, "only Commercial Welding has a traced level"
  end

  test "a brand page shows the typeface hierarchy at full size beside its colours" do
    log_in_as(@admin)
    HIERARCHIES.each do |brand, levels|
      get logo_brand_path(brand)
      assert_select "section[data-test='brand-typefaces'] h2", "Typefaces"
      assert_equal levels.map { |role, name, _| [role, name] }, hierarchy_shown("[data-test='brand-typefaces']"), brand
      sizes = faces_shown("[data-test='brand-typefaces']").map { |_, px, _| px }.compact
      assert_equal sizes.sort.reverse, sizes, "#{brand}: the sizes step down"
    end
    get logo_brand_path("studio")
    assert_equal [[800, 30, true], [300, 20, true], [500, 15, true]], faces_shown("[data-test='brand-typefaces']")
  end

  test "the index lists Turf Monster and Commercial Welding beside the first two, each with a true typeface" do
    log_in_as(@admin)
    get logos_path
    assert_response :success

    assert_equal %w[studio industries turf welding], css_select("[data-test='logo-brand-row']").map { |row| row["data-brand"] }
    assert_equal [%w[Display Montserrat\ ExtraBold], %w[Text Montserrat\ Medium]], hierarchy_shown("[data-brand='turf'] [data-test='logo-typeface']")
    assert_equal [["Display", "Traced lettering (face not identified)"], ["Tagline", "Montserrat Medium"]],
                 hierarchy_shown("[data-brand='welding'] [data-test='logo-typeface']")

    { "turf" => "Turf Monster", "welding" => "Commercial Welding" }.each do |brand, name|
      assert_select "[data-test='logo-brand-row'][data-brand='#{brand}']" do
        assert_select "th a[href=?]", logo_brand_path(brand), text: name
        SAMPLES.each_key do |type|
          src, alt = sample(brand, name, type, "light")
          assert_select "[data-test='logo-cluster'] [data-test='logo-sample'][data-type='#{type}'] img[alt=?][src=?]", alt, src
        end
      end
    end
  end

  test "the admin tools list links to the page" do
    log_in_as(@admin)
    get logos_path
    assert_select "a[href=?]", logos_path, text: /Logos/
  end

  # What a brand page's logo images, downloads and copy payloads must be for a list of variants, in page order (per
  # example, its light version then its dark one; a watermark page has one version per example).
  def assert_examples(variants, examples: variants.size)
    assert_select "[data-test='logo-example']", examples
    assert_equal variants.map(&:label), css_select("img[data-test='logo-image']").map { |img| img["alt"] }, "each image names its type, text and context"
    assert_equal variants.map { |v| public_send(:"#{v.type}_logo_path", v.logo.brand, v.params) }, css_select("img[data-test='logo-image']").map { |img| img["src"] }
    assert_equal variants.map { |v| public_send(:"#{v.type}_logo_path", v.logo.brand, v.params.merge(download: 1)) },
                 css_select("a[data-test='logo-download']").map { |link| link["href"] }
    assert_equal variants.map { |v| "Download: #{v.label}" }, css_select("a[data-test='logo-download']").map { |link| link["aria-label"] }
    assert_equal variants.map(&:svg), css_select("button[data-test='logo-copy']").map { |button| button["data-clip"] }, "copy gives the logo as shown"
    assert_equal variants.map { |v| "Copy SVG: #{v.label}" }, css_select("button[data-test='logo-copy']").map { |button| button["aria-label"] }
  end

  def variants(brand, type, **choices) = Logos::Variant.all(Logos::Variant.logo(brand, type), type:, **choices)

  # A page that follows the hub theme: each example's light and dark versions, in page order.
  def themed(brand, type, **choices) = variants(brand, type, tone: :light, **choices).zip(variants(brand, type, tone: :dark, **choices)).flatten

  # The light and dark versions of an example are wrapped so CSS on html.dark shows one.
  def assert_themed_pairs(count)
    assert_select "[data-test='logo-themed'][data-tone='light'].contents.dark\\:hidden img[data-test='logo-image'][src*='tone=light']", count
    assert_select "[data-test='logo-themed'][data-tone='dark'].hidden.dark\\:contents img[data-test='logo-image'][src*='tone=dark']", count
  end

  test "a brand page opens on the Navbar Logo tab at the rule of 4: three text versions, each with a download and a copy" do
    log_in_as(@admin)
    get logo_brand_path("industries")
    assert_response :success

    assert_select "[data-test='logo-type'][data-type='navbar']", 1
    assert_select "[data-test='logo-rule']", 0, "the two rule sections are gone: the Rule control picks one"
    assert_equal %w[homogeneous first second], css_select("[data-test='logo-example']").map { |example| example["data-text"] }
    assert_equal ["Homogeneous", "First word leads", "Second word leads"], css_select("[data-test='logo-example'] h2").map { |h| h.text.strip }
    assert_examples themed("industries", :navbar, rule: 4), examples: 3
    assert_themed_pairs(3)
    assert_select "img[data-test='logo-image'][alt=?][src=?]", LABEL, navbar_logo_path("industries", rule: 4, text: "second", tone: "light", guides: 0)
    assert_select "[data-test='logo-plate'], [data-test='logo-type'] [style*='background']", 0, "no plate: each logo sits on the page's own background"
    assert_select "[data-test='logo-frame']", 3
    assert_select "[data-logo-theme]", 0, "with no context the page leaves the hub theme as it is"
    assert_select "[data-test='type-sentence']", { count: 1, text: /\AThe icon is four rows tall.*the middle two rows\.\z/ }
    assert_select "[data-test='guides-sentence']", 0
    assert_select "[data-test='transparent-note']", /Every logo file has a transparent background/
    assert_select "[data-test='watermark-note']", 0
    assert_includes response.body, "window.copyText"
    # Every control on the page has the page's own focus ring: the tabs, the Rule options, the guides toggle, Download and Copy SVG.
    ringed = css_select(".btn").select { |control| control["class"].include?("focus-visible:outline-[#4338CA]! dark:focus-visible:outline-white!") }
    assert_equal %w[logo-tab logo-tab logo-tab rule-option rule-option guides-toggle] + %w[logo-download logo-copy] * 6, ringed.map { |control| control["data-test"] }
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
      assert_examples themed("studio", :navbar, rule:), examples: 3
      assert_select "img[data-test='logo-image'][alt*='rule of #{rule}']", 6
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
      assert_examples themed(brand, :stacked), examples: 3
      assert_select "img[data-test='logo-image'][alt*=' stacked logo, '][src^=?]", stacked_logo_path(brand), 6
      assert_select "[data-test='type-sentence']", { count: 1, text: /\AThe 3-2-1 method: .*3 units tall, every gap is 2 units.*1 unit tall.*60% of the big word's width/ }
      assert_select "[data-test='type-sentence']", form
      assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path(brand, type: "stacked", guides: 1), text: "Show guides"

      get logo_brand_path(brand, type: "stacked", guides: 1)
      assert_response :success
      assert_examples themed(brand, :stacked, guides: true), examples: 3
      assert_select "img[data-test='logo-image'][alt$='construction guides'][src*='guides=1']", 6
      assert_equal 6, css_select("button[data-test='logo-copy']").count { |button| button["data-clip"].include?(%(<g class="guide-ghosts")) }
      assert_select "[data-test='guides-sentence']", brand == "turf" ? /faint copies of the name at a third of its size: one copy per unit/ : /faint copies of the small word: one copy per unit/
      assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path(brand, type: "stacked"), text: "Hide guides"
    end
  end

  test "the Icon tab shows the icon alone with a download and a copy, and no rule or guides" do
    log_in_as(@admin)
    [nil, *CONTEXTS].each do |context|
      get logo_brand_path("welding", { type: "icon", context:, guides: 1, rule: 3 }.compact)
      assert_response :success
      tones = context == "watermark" ? %w[watermark] : %w[light dark]
      assert_examples tones.flat_map { |tone| variants("welding", :icon, tone: tone.to_sym) }, examples: 1
      tones.each do |tone|
        assert_select "img[data-test='logo-image'][alt=?][src=?]", "Commercial Welding icon, #{tone}", icon_logo_path("welding", tone:)
        assert_select "a[data-test='logo-download'][href=?]", icon_logo_path("welding", tone:, download: 1)
      end
      assert_select "[data-test='logo-frame']", 1
      assert_select "[data-test='logo-plate']", 0
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

    # Light and dark are the hub's theme, which every page keeps already: a link never carries them.
    get logo_brand_path("turf", context: "dark", guides: 1)
    assert_equal [logo_brand_path("turf", rule: 3, guides: 1), logo_brand_path("turf", guides: 1)],
                 css_select("a[data-test='rule-option']").map { |option| option["href"] }
    assert_equal [%w[guides 1]], css_select("form[data-test='context-form'] input[type='hidden']").map { |i| [i["name"], i["value"]] }
    assert_select "a[data-test='logos-crumb'][href=?]", logos_path
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf"), text: "Hide guides"

    # The defaults (Navbar Logo, the theme's logos, rule of 4, guides off) are left out, even when named.
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
      assert_equal type == "icon" ? 2 : 6, alts.uniq.size, "each version in light and in dark"
      assert alts.all? { |alt| alt.start_with?("#{name} #{Logos::Variant::TYPES.fetch(type.to_sym).downcase}, ") }, alts.inspect
    end
  end

  test "the Context control offers light, dark and watermark, drives the hub theme, and the logos follow it on every tab" do
    log_in_as(@admin)
    [nil, *CONTEXTS].product(%w[icon navbar stacked]).each do |context, type|
      get logo_brand_path("industries", { type:, context: }.compact)
      assert_response :success
      where = "#{context.inspect} #{type}"

      assert_select "form[data-test='context-form'][method='get'][action=?]", logo_brand_path("industries"), 1 do
        assert_select "label[for='logo-context']", "Context"
        assert_select "select#logo-context[name='context']:not([onchange])", 1
        assert_equal [%w[light Light], %w[dark Dark], %w[watermark Watermark]], css_select("select#logo-context option").map { |o| [o["value"], o.text] }
        assert_equal [context].compact, css_select("select#logo-context option[selected]").map { |o| o["value"] }, where
        assert_select "noscript input[type='submit'][value='Apply']", 1, "the form works with JavaScript off"
        assert_select "input[type='submit']", 1, "and with JavaScript on there is no button: the control acts on change"
        assert_select "input[name='guides']", 0
      end
      select = css_select("select#logo-context").first
      assert_equal ["true", (context == "watermark").to_s], [select["data-logo-context"], select["data-watermark"]], where

      # An explicit context sets the hub theme on load (watermark sets dark); none leaves it.
      pin = { nil => nil, "light" => "light", "dark" => "dark", "watermark" => "dark" }.fetch(context)
      assert_equal [pin].compact, css_select("[data-logo-theme]").map { |page| page["data-logo-theme"] }, where

      count = type == "icon" ? 1 : 3
      assert_select "[data-test='logo-plate']", 0
      if context == "watermark"
        assert_examples variants("industries", type.to_sym, tone: :watermark), examples: count
        assert_select "[data-test='logo-themed']", 0
      else
        assert_examples themed("industries", type.to_sym), examples: count
        assert_themed_pairs(count)
        assert_select "img[data-test='logo-image'][src*='tone=watermark']", 0
      end
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

  test "the index shows one logo of each type per brand in the theme's tones or the watermark, and only the watermark is carried" do
    log_in_as(@admin)
    [nil, *CONTEXTS].each do |context|
      get logos_path({ context: }.compact)
      assert_response :success
      carried = context == "watermark" ? { context: } : {}
      tones = context == "watermark" ? %w[watermark] : %w[light dark]

      assert_select "form[data-test='context-form'][method='get'][action=?]", logos_path, 1
      assert_select "form[data-test='context-form'] noscript input[type='submit'][value='Apply']", 1
      assert_select "form[data-test='context-form'] > input[type='submit']", 0
      assert_equal [context].compact, css_select("select#logo-context option[selected]").map { |o| o["value"] }
      assert_select "[data-test='logo-plate']", 0
      assert_select "[data-test='logo-image']", 3 * tones.size * Logos::NavbarLogo.brands.size
      Logos::NavbarLogo.brands.each do |brand|
        name = Logos::Variant.brand_name(Logos::NavbarLogo.new(brand))
        assert_select "[data-test='logo-brand-row'][data-brand='#{brand}']" do
          assert_select "a[href=?]", logo_brand_path(brand, carried), 2, "the name and the navbar logo open the default tab"
          SAMPLES.keys.product(tones).each do |type, tone|
            src, alt = sample(brand, name, type, tone)
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
    assert_examples themed("industries", :navbar, rule: 3, guides: true), examples: 3
    assert_select "img[data-test='logo-image'][src*='guides=1'][alt$='construction guides']", 6
    assert_select "a[data-test='logo-download'][href*='guides=1']", 6
    assert_equal 6, css_select("button[data-test='logo-copy']").count { |button| button["data-clip"].include?("<line") }
    assert_select "[data-test='guides-sentence']", /the numbered rows, filled with faint copies of the name one row tall, so the rows can be counted against the icon; the icon's right edge and where the name starts\.\s+They are for looking at, never for shipping\. A drawing never shrinks below a readable size: where one is wider than its frame, scroll it sideways\./

    # A guide drawing fits its frame (max-width) down to a least width of its own, where its frame starts to scroll.
    # One frame per example holds both tones' drawings; its name is the drawing's, without the tone.
    assert_select "[data-test='logo-frame'].overflow-x-auto[role='group'][aria-label^='Guide drawing: McRitchie Industries navbar logo']", 3
    assert_equal ["Guide drawing: McRitchie Industries navbar logo, rule of 3, homogeneous, construction guides"],
                 css_select("[data-test='logo-frame']").first(1).map { |frame| frame["aria-label"] }
    # A tab stop as served (so it works with JavaScript off); scroll_tab_stop.js drops the tabindex wherever the drawing fits.
    assert_select "[data-test='logo-frame'][tabindex='0'][data-scroll-tab-stop]", 3
    assert_select "[data-test='logo-frame'][x-data], [data-test='logo-frame'][x-init]", 0
    styles = css_select("[data-test='logo-frame'] img.max-w-full").map { |img| img["style"] }
    assert_equal 6, styles.size
    styles.each { |style| assert_match(/\Amax-height: 132px; min-width: [5-6]\d\dpx\z/, style) }
    get logo_brand_path("industries", type: "stacked", guides: 1)
    assert_equal ["max-height: 540px; min-width: 480px", "max-height: 540px; min-width: 476px", "max-height: 540px; min-width: 467px"],
                 css_select("[data-test='logo-frame'].overflow-x-auto [data-tone='light'] img.max-w-full").map { |img| img["style"] }
    get logo_brand_path("industries", type: "stacked")
    assert_select "[data-test='logo-frame'].overflow-x-auto, [data-test='logo-frame'][tabindex]", 0
    assert_select "[data-test='logo-frame'] img[style='max-height: 240px'].max-w-full", 6
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
    assert_match(/\Ainline; filename="industries-stacked-two-line-first-light\.svg"/, response.headers["Content-Disposition"])
    assert_no_match(/<text|<line/, response.body)

    get stacked_logo_path("industries", tone: "dark", guides: 1, download: 1, rule: 9)
    assert_response :success, "a stacked logo has no rule, so the param is not read"
    assert_equal logo.svg(tone: :dark, guides: true), response.body
    assert_match(/\Aattachment; filename="industries-stacked-two-line-homogeneous-dark-guides\.svg"/, response.headers["Content-Disposition"])
    assert_equal %w[1 2 1 2 3 1 2 1 1], Nokogiri::XML(response.body).remove_namespaces!.css("text").map(&:text), "the ruler's numbers and the icon's 1"

    get stacked_logo_path("turf", text: "second", tone: "watermark")
    assert_equal Logos::StackedLogo.new("turf").svg(text: :second, tone: :watermark), response.body
    assert_match(/filename="turf-stacked-one-line-second-watermark\.svg"/, response.headers["Content-Disposition"])
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

  # Task stacked-tagline-and-ghost-grid: the Stacked tab's Form control.
  test "the Stacked tab offers each brand's own form and With tagline where the brand has a tagline" do
    log_in_as(@admin)
    { "studio" => [%w[two_line tagline], ["Two lines", "With tagline"]], "industries" => [%w[two_line tagline], ["Two lines", "With tagline"]],
      "welding" => [%w[two_line tagline], ["Two lines", "With tagline"]], "turf" => [%w[one_line], ["One line"]] }.each do |brand, (forms, words)|
      get logo_brand_path(brand, type: "stacked")
      assert_response :success
      assert_select "[data-test='form-control'][role='group'][aria-label='Form']", 1
      options = css_select("a[data-test='form-option']")
      assert_equal forms, options.map { |option| option["data-form"] }, brand
      assert_equal words, options.map { |option| option.text.strip }, brand
      assert_equal [forms.first], css_select("a[data-test='form-option'][aria-current='true']").map { |option| option["data-form"] }, "#{brand}: its own form"
      assert_equal logo_brand_path(brand, type: "stacked"), options.first["href"], "#{brand}: its own form is the default, left out"
      if brand == "turf"
        assert_select "[data-test='no-tagline']", { count: 1, text: "Turf Monster has no tagline, so there is no tagline form." }
      else
        assert_equal logo_brand_path(brand, type: "stacked", form: "tagline"), options.last["href"]
        assert_select "[data-test='no-tagline']", 0
      end
    end
    %w[icon navbar].each do |type|
      get logo_brand_path("studio", type:, form: "tagline")
      assert_response :success
      assert_select "[data-test='form-control'], [data-test='no-tagline']", 0, "only the Stacked Logo has a form"
    end
  end

  test "the tagline form is drawn, named in each download and alt text, and stated in plain words" do
    log_in_as(@admin)
    get logo_brand_path("welding", type: "stacked", form: "tagline", guides: 1)
    assert_response :success
    assert_examples themed("welding", :stacked, form: :tagline, guides: true), examples: 3
    assert_equal ["tagline"], css_select("a[data-test='form-option'][aria-current='true']").map { |option| option["data-form"] }
    assert_equal %w[welding-stacked-tagline-homogeneous-light-guides.svg welding-stacked-tagline-first-light-guides.svg welding-stacked-tagline-second-light-guides.svg],
                 variants("welding", :stacked, form: :tagline, guides: true).map(&:filename), "the files the Download links above serve"
    assert_select "img[data-test='logo-image'][alt^='Commercial Welding stacked logo, with tagline, ']", 6
    assert_select "[data-test='type-sentence']", /With tagline: the whole name on one line, 3 units tall, then 2 units, then the tagline, 1 unit tall/
    assert_select "[data-test='guides-sentence']", /faint copies of the tagline: one copy per unit/

    get stacked_logo_path("welding", form: "tagline", text: "first", tone: "light", download: 1)
    assert_response :success
    assert_equal Logos::StackedLogo.new("welding").svg(form: :tagline, text: :first), response.body
    assert_match(/\Aattachment; filename="welding-stacked-tagline-first-light\.svg"/, response.headers["Content-Disposition"])
  end

  test "the form is kept across every other control, and every other control's setting across the form" do
    log_in_as(@admin)
    get logo_brand_path("studio", type: "stacked", form: "tagline", context: "watermark", guides: 1)
    assert_response :success
    kept = { context: "watermark", form: "tagline", guides: 1 }
    assert_equal [logo_brand_path("studio", kept.merge(type: "icon")), logo_brand_path("studio", kept), logo_brand_path("studio", kept.merge(type: "stacked"))],
                 css_select("a[data-test='logo-tab']").map { |tab| tab["href"] }
    assert_equal [%w[type stacked], %w[form tagline], %w[guides 1]], css_select("form[data-test='context-form'] input[type='hidden']").map { |i| [i["name"], i["value"]] }
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("studio", type: "stacked", context: "watermark", form: "tagline"), text: "Hide guides"
    assert_equal [logo_brand_path("studio", type: "stacked", context: "watermark", guides: 1), logo_brand_path("studio", type: "stacked", context: "watermark", form: "tagline", guides: 1)],
                 css_select("a[data-test='form-option']").map { |option| option["href"] }

    get logo_brand_path("studio", form: "tagline", rule: 3)
    assert_equal [logo_brand_path("studio", form: "tagline", rule: 3), logo_brand_path("studio", form: "tagline")],
                 css_select("a[data-test='rule-option']").map { |option| option["href"] }, "the Navbar tab carries the form to the Stacked tab"
    assert_equal logo_brand_path("studio", type: "stacked", rule: 3, form: "tagline"), css_select("a[data-test='logo-tab'][data-type='stacked']").first["href"]
  end

  test "an unknown form, or a form the brand does not draw, is a 422 in plain text" do
    log_in_as(@admin)
    { logo_brand_path("studio", type: "stacked", form: "three_line") => /unknown form "three_line": expected one of two_line, tagline/,
      logo_brand_path("turf", type: "stacked", form: "tagline") => /unknown form "tagline": expected one of one_line/,
      logo_brand_path("studio", type: "stacked", form: "one_line") => /unknown form "one_line"/,
      logo_brand_path("studio", form: "sideways") => /unknown form "sideways": expected one of two_line, one_line, tagline/,
      stacked_logo_path("studio", form: "") => /unknown form ""/,
      stacked_logo_path("turf", form: "tagline") => /unknown form "tagline"/,
      stacked_logo_path("industries", form: %w[tagline]) => /unknown form/ }.each do |path, message|
      get path
      assert_response :unprocessable_content, path
      assert_equal "text/plain", response.media_type
      assert_match message, response.body
    end
    get navbar_logo_path("studio", form: "sideways")
    assert_response :success, "a Navbar Logo has no form, so the param is not read"
  end
end
