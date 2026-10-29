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
  OWN_FORMS = { "studio" => "two_line", "industries" => "two_line", "turf" => "one_line", "welding" => "two_line", "welding_v2" => "two_line" }.freeze

  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  def requests
    { index: -> { get logos_path }, show: -> { get logo_brand_path("industries") },
      compare: -> { get logos_compare_path(left: "welding", right: "welding_v2", grid: 1) },
      icon: -> { get icon_logo_path("industries", tone: "dark") },
      navbar: -> { get navbar_logo_path("industries", rule: 4, text: "second") },
      stacked: -> { get stacked_logo_path("industries", text: "first") },
      kit_export: -> { get brand_kit_export_path("industries") },
      kit_file: -> { get brand_kit_file_path("industries", "navbar-dark.svg") } }
  end

  # The sample of one type the index shows for a brand: [its SVG route, its accessible name]. A page shows a brand's
  # Original where it has one (task logo-original-and-alt), except in a watermark, which has no colouring.
  def sample(brand, name, type, context)
    params, words = SAMPLES.fetch(type)
    # A brand whose style names its kit's text version (`kit_text`: Commercial Welding v1 is homogeneous) shows that.
    if type != "icon" && (text = BrandKit.defaults(brand, type)[:text].to_s) != params[:text]
      words = words.sub(Logos::Variant::TEXTS.fetch(params[:text].to_sym).downcase, Logos::Variant::TEXTS.fetch(text.to_sym).downcase)
      params = params.merge(text:)
    end
    guides = type == "icon" ? {} : { guides: 0 }
    if type == "stacked"
      params = params.merge(form: OWN_FORMS.fetch(brand))
      words = format(words, form: Logos::Variant::FORMS.fetch(OWN_FORMS.fetch(brand).to_sym).downcase)
    end
    original = context != "watermark" && Logos::NavbarLogo.new(brand).original?
    # An icon names its colouring, Alt included (task kit-export-and-clear-lens: with none it draws the kit icon).
    colouring = original ? { colouring: "original" } : ({ colouring: "alt" } if type == "icon").to_h
    [public_send(:"#{type}_logo_path", brand, params.merge(tone: context, **colouring, **guides)),
     "#{name} #{words}, #{context}#{', original colouring' if original}"]
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
      assert_equal "#{LABEL}, original colouring", sample("industries", "McRitchie Industries", "navbar", "light").last
      assert_select "[data-test='logo-plate']", 0, "no plate: the logos sit on the page's own background"
    end
    assert_equal %w[Stacked Navbar Icon], css_select("[data-brand='studio'] [data-test='logo-badge']").map { |badge| badge.text.strip }
    assert_equal({ "stacked" => "max-height: 88px", "navbar" => "max-height: 28px", "icon" => "max-height: 28px" },
                 css_select("[data-brand='studio'] [data-test='logo-sample']").to_h { |cell| [cell["data-type"], cell.at_css("img")["style"]] })
    assert_select "[data-test='kit-note']", /saved kit choices where it has them \(marked Saved\), else its defaults/
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

  # The palettes Alex McRitchie chose (epic brand-studio, 2026-10-10 22:45), in order, as config/logo_brands.yml lists them.
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

  # Task brand-colour-spectrum-ramps: every palette colour as an eleven-step ramp of copy buttons, the brand's hex on
  # one step, and the CSS tokens behind one more copy button.
  test "a brand page shows a copyable 50-950 spectrum for every palette colour and its CSS tokens" do
    log_in_as(@admin)
    get logo_brand_path("welding_v2")
    assert_response :success
    assert_select "section[data-test='brand-spectrum'] h2", "Spectrum"
    palette = [["Welding Blue", "#2D5E8E"], ["Spark Orange", "#D7602E"], ["Ember", "#F08A5A"], ["White", "#FFFFFF"]]
    ramps = css_select("[data-test='logo-spectrum-ramp']")
    assert_equal palette.map(&:first), ramps.map { |ramp| ramp["data-name"] }
    ramps.zip(palette).each do |ramp, (name, hex)|
      steps = ramp.css("[data-test='logo-spectrum-step']")
      assert_equal %w[50 100 200 300 400 500 600 700 800 900 950], steps.map { |step| step["data-step"] }, name
      assert_equal [hex], steps.select { |step| step.key?("data-anchor") }.map { |step| step["data-hex"] }, name
      assert_equal [hex], ramp.css("[data-test='logo-spectrum-brand']").map { |label| label.ancestors("li").first["data-hex"] }, name
      steps.each { |step| assert_equal step["data-hex"], step.at_css("button[data-copy-hex]")["data-copy-hex"], "#{name} #{step['data-step']}" }
    end
    assert_select "[data-test='logo-spectrum-step'][data-step='700'][data-hex='#2D5E8E'] [data-test='logo-spectrum-contrast']", "6.8:1 AA"
    copy_css = css_select("[data-test='logo-spectrum-copy-css']").first["data-copy-hex"]
    assert_includes copy_css, "--welding-v2-welding-blue-700: #2D5E8E;"
    assert_select "[data-test='logo-spectrum-tokens'] pre", /--welding-v2-ember-400: #F08A5A;/
  end

  # The typeface hierarchies Alex McRitchie asked for (at most three levels, the most prominent first), as [role, name shown].
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
                    "Commercial Welding v1 navbar logo, rule of 4, homogeneous, light"
      assert_select "[data-test='logo-themed'][data-tone='dark'].hidden img[src=?]",
                    navbar_logo_path("welding", rule: 4, text: "homogeneous", tone: "dark", guides: 0)
      assert_select "[data-test='logo-typeface-name'][style]", 0, "no font is claimed for traced lettering"
    end
    assert_select "[data-test='logo-typeface-traced']", 2, "only Commercial Welding v1 and v2 have a traced level"
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

    assert_equal %w[studio industries turf welding welding_v2], css_select("[data-test='logo-brand-row']").map { |row| row["data-brand"] }
    assert_equal [%w[Display Montserrat\ ExtraBold], %w[Text Montserrat\ Medium]], hierarchy_shown("[data-brand='turf'] [data-test='logo-typeface']")
    assert_equal [["Display", "Traced lettering (face not identified)"], ["Tagline", "Montserrat Medium"]],
                 hierarchy_shown("[data-brand='welding'] [data-test='logo-typeface']")

    { "turf" => "Turf Monster", "welding" => "Commercial Welding v1" }.each do |brand, name|
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

  # What a brand page's ONE logo (task logo-download-card) must be for its variants in page order (its light version
  # then its dark one; a watermark page has one): the images, and the Download card, whose Download link starts on the
  # first tone shown and whose tone radios carry every tone's SVG and download URL. The card has no Copy SVG (task
  # brand-page-split-layout).
  def assert_examples(variants, examples: 1)
    assert_select "[data-test='logo-example']", examples
    assert_equal variants.map(&:label), css_select("img[data-test='logo-image']").map { |img| img["alt"] }, "each image names its type, text and context"
    assert_equal variants.map { |v| logo_route(v) }, css_select("img[data-test='logo-image']").map { |img| img["src"] }
    first = variants.first
    assert_select "button[data-test='logo-copy']", 0
    assert_equal [logo_route(first, download: 1)], css_select("a[data-test='logo-download']").map { |link| link["href"] }
    assert_equal ["Download: #{first.label}"], css_select("a[data-test='logo-download']").map { |link| link["aria-label"] }
    variants.each do |v|
      assert_select "input[data-test='download-tone-option'][value=?][data-svg=?][data-download-url=?][data-filename=?]",
                    v.tone.to_s, logo_route(v), logo_route(v, download: 1), v.filename
    end
  end

  def logo_route(variant, **more) = public_send(:"#{variant.type}_logo_path", variant.logo.brand, variant.params.merge(more))

  # Every tone's download URL on the Download card, light, dark and watermark.
  def download_urls = css_select("input[data-test='download-tone-option']").map { |input| input["data-download-url"] }

  # In the brand's own page colouring: its Original where it has one (task logo-original-and-alt); in the type's
  # default text version (BrandKit::DEFAULTS) unless asked. One variant: the tab draws one logo.
  def variants(brand, type, **choices)
    logo = Logos::Variant.logo(brand, type)
    defaults = type == :icon ? {} : { text: BrandKit.defaults(brand, type).fetch(:text), rule: 4 }
    [Logos::Variant.new(logo, type:, colouring: logo.colourings.first, **defaults.merge(choices))]
  end

  # A page that follows the hub theme: the logo's light and dark versions, in page order.
  def themed(brand, type, **choices) = variants(brand, type, tone: :light, **choices) + variants(brand, type, tone: :dark, **choices)

  # The light and dark versions of an example are wrapped so CSS on html.dark shows one.
  def assert_themed_pairs(count)
    assert_select "[data-test='logo-themed'][data-tone='light'].contents.dark\\:hidden img[data-test='logo-image'][src*='tone=light']", count
    assert_select "[data-test='logo-themed'][data-tone='dark'].hidden.dark\\:contents img[data-test='logo-image'][src*='tone=dark']", count
  end

  # Task brand-page-split-layout: the header holds the brand (a crumb, not a big title), the type tabs and Context;
  # under it the logo sits beside the edit panel, then the Download card beside the controls. Guides give the drawing
  # the top row and take the Download card away, the edit panel taking its place.
  test "a brand page is a header, then the logo beside the edit panel, then Download beside the controls" do
    log_in_as(@admin)
    %w[navbar stacked icon].each do |type|
      get logo_brand_path("studio", type:)
      assert_response :success
      assert_select "header[data-test='logo-header']" do
        assert_select "nav[aria-label='Breadcrumb'] h1.text-sm", "McRitchie Studio"
        assert_select "[data-test='logo-tabs'] [data-test='logo-tab']", 3
        assert_select "[data-test='context-form']", 1
        assert_select "[data-test='kit-status']", 1
      end
      assert_select "[data-test='logo-type'][data-layout='split']", 1, type
      assert_select "[data-test='logo-top'].lg\\:grid-cols-2 > [data-test='logo-example'] + [data-test='edit-panel']", 1, type
      assert_select "[data-test='logo-bottom'].lg\\:grid-cols-2 > [data-test='download-card'] + [data-test='logo-control-card']", 1, type
      assert_select "[data-test='logo-text-card'], [data-test='logo-about'], [data-test='type-sentence'], [data-test='transparent-note'], [data-test='brand-note']", 0,
                    "no words about the logo (Alex McRitchie 2026-10-27: drop the text)"
      # One line per control: its name on the left, its options on the right.
      css_select("[data-test='logo-controls'] > [role='group']").each do |group|
        assert_includes group["class"], "justify-between"
        assert_equal 1, group.css("> div.justify-end").size, group["data-test"]
      end
      assert_select "[data-test='logo-control-card'] [data-test='compare-link']", 1
      assert_select "[data-test='logo-control-card'] [data-test='kit-default-state']", 1
      # The card: PNG first and chosen, Dark first, one Download, no Copy SVG, a Width × Height with Keep aspect ratio.
      assert_equal %w[png svg], css_select("input[data-test='download-format-option']").map { |input| input["value"] }
      assert_select "input[data-test='download-format-option'][value='png'][checked]", 1
      assert_equal "dark", css_select("input[data-test='download-tone-option']").first["value"]
      assert_select "a[data-test='logo-download']", { count: 1, text: "Download" }
      assert_select "[data-test='logo-copy']", 0
      assert_select "[data-test='download-format-tone'].sm\\:grid-cols-2 > [data-test='download-format'] + [data-test='download-tone']", 1, "Format and Tone in halves"
      sizes = css_select("input[data-test='download-size-option']").map { |input| input["value"] }
      assert_equal Logos::PngSizes::STANDARD.fetch(type.to_sym) + ["custom"], sizes, "six standard sizes and Custom"
      # Each named by its long side alone; Width × Height gives both.
      names = css_select("[data-download-size-label] [data-size-text]").map { |span| span.text }
      assert(names.all? { |name| name.match?(/\A\d+\z/) }, names.inspect)
      assert_select "[data-test='download-format'].text-center > div.justify-center, [data-test='download-tone'].text-center > div.justify-center, [data-test='download-size'].text-center > div.justify-center", 3
      assert_select "[data-test='download-custom'] > div.justify-center", 1, "Width × Height centred"
      assert_select "[data-test='download-custom'] input[data-test='download-keep-aspect'][disabled]", 1, "live only on Custom"
      assert_select "[data-test='edit-panel'] p", { text: /Pick (each part's|the icon's) colour/, count: 0 }
      assert_equal [Logos::PngSizes::DEFAULTS.fetch(type.to_sym)], css_select("input[data-test='download-size-option'][checked]").map { |input| input["value"] }
      assert_select "[data-test='download-background'], [name='background']", 0, "a PNG is transparent"
      assert_select "a[data-test='logo-download'].w-full", 1
      assert_select "input[data-test='download-custom-width'][name='custom_width']", 1
      assert_select "input[data-test='download-custom-height'][name='custom_height']", 1
      assert_select "input[data-test='download-keep-aspect'][type='checkbox'][checked]", 1
      assert_select "[data-test='logo-frame'] [data-test='download-canvas-outline'][hidden]", 1
    end

    get logo_brand_path("studio", type: "stacked", guides: 1)
    assert_select "[data-test='logo-type'][data-layout='row']", 1
    assert_select "[data-test='guides-sentence']", 0, "no words under the drawing"
    assert_select "[data-test='logo-frame'] img[style^='max-height: 280px']", 2, "no taller than the card it replaces"
    assert_select "[data-test='logo-top'] > [data-test='logo-example'].lg\\:col-span-2", 1, "the guide drawing takes the row"
    assert_select "[data-test='logo-top'] > [data-test='edit-ghost'].invisible.hidden.lg\\:block[inert][aria-hidden='true'] [data-test='edit-panel']", 1,
                  "the edit panel put away, keeping the row's height"
    assert_select "[data-test='logo-top'] > [data-test='edit-panel']", 0
    assert_select "[data-test='edit-jump']", 0
    assert_select "[data-test='logo-bottom'] > [data-test='download-card'] + [data-test='logo-control-card']", 1, "Download stays"
    get logo_brand_path("studio", type: "icon", guides: 1)
    assert_select "[data-test='logo-top'] > [data-test='edit-panel']", 1, "the icon has no guide drawing, so it keeps its edit panel"
  end

  # Task logo-download-card: ONE logo per tab, in the kit's text version (here the default, second word leads), with
  # one Download card; the Words control picks another. It was three text versions, each with its own download and copy.
  test "a brand page opens on the Navbar Logo tab at the rule of 4: one logo, in the kit's text version, with a Download card" do
    log_in_as(@admin)
    get logo_brand_path("industries")
    assert_response :success

    assert_select "[data-test='logo-type'][data-type='navbar']", 1
    assert_select "[data-test='logo-rule']", 0, "the two rule sections are gone: the Rule control picks one"
    assert_equal %w[second], css_select("[data-test='logo-example']").map { |example| example["data-text"] }
    assert_select "[data-test='logo-example'] h2", 0, "one logo needs no version heading"
    assert_equal [["homogeneous", "Homogeneous"], ["first", "First word leads"], ["second", "Second word leads"]],
                 css_select("[data-test='text-control'] a[data-test='text-option']").map { |option| [option["data-text"], option.text.strip] }
    assert_equal ["second"], css_select("a[data-test='text-option'][aria-current='true']").map { |option| option["data-text"] }
    assert_equal [logo_brand_path("industries", text: "homogeneous"), logo_brand_path("industries", text: "first"), logo_brand_path("industries")],
                 css_select("a[data-test='text-option']").map { |option| option["href"] }, "the kit's text version is the default, left out"
    assert_examples themed("industries", :navbar, rule: 4)
    assert_themed_pairs(1)
    assert_equal %w[dark light watermark], css_select("input[data-test='download-tone-option']").map { |input| input["value"] }, "Dark first"
    assert_select "img[data-test='logo-image'][alt=?][src=?]", "#{LABEL}, original colouring",
                  navbar_logo_path("industries", rule: 4, text: "second", tone: "light", colouring: "original", guides: 0)
    assert_select "[data-test='logo-plate'], [data-test='logo-example'] [style*='background']", 0, "no plate: each logo sits on the page's own background"
    assert_select "[data-test='logo-frame']", 1
    assert_select "[data-logo-theme]", 0, "with no context the page leaves the hub theme as it is"
    assert_select "[data-test='guides-sentence']", 0
    assert_select "[data-test='watermark-note']", 0
    assert_includes response.body, "window.copyText"
    # Every control on the page has the page's own focus ring: the tabs, the Rule options, the guides toggle, Download and Copy SVG.
    ringed = css_select(".btn").select { |control| control["class"].include?("focus-visible:outline-[#4338CA]! dark:focus-visible:outline-white!") }
    assert_equal %w[logo-tab logo-tab logo-tab logo-download colouring-option colouring-option rule-option rule-option rule-option] +
                 %w[text-option] * 3 + %w[guides-toggle kit-save-default compare-link edit-jump kit-save kit-download] +
                 %w[kit-pick-open kit-pick-download kit-pick-download] * 3 + %w[kit-notes-save kit-original-upload], ringed.map { |control| control["data-test"] }
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
    { nil => 4, "4" => 4, "3" => 3, "6" => 6 }.each do |param, rule|
      get logo_brand_path("studio", { rule: param }.compact)
      assert_response :success
      assert_select "[data-test='rule-control'][role='group'][aria-label='Rule']", 1
      assert_equal [["3", "Rule of 3", logo_brand_path("studio", rule: 3)], ["4", "Rule of 4", logo_brand_path("studio")], ["6", "Rule of 6", logo_brand_path("studio", rule: 6)]],
                   css_select("a[data-test='rule-option']").map { |option| [option["data-rule"], option.text.strip, option["href"]] }
      assert_equal [rule.to_s], css_select("a[data-test='rule-option'][aria-current='true']").map { |option| option["data-rule"] }
      assert_select "a[data-test='rule-option'][aria-current='true'].btn-primary.border.border-transparent", 1
      assert_examples themed("studio", :navbar, rule:)
      assert_select "img[data-test='logo-image'][alt*='rule of #{rule}']", 2
    end
    %w[icon stacked].each do |type|
      get logo_brand_path("studio", type:, rule: 3)
      assert_select "[data-test='rule-control']", 0, "only the Navbar Logo has a rule"
    end
  end

  # Option A (Alex McRitchie 2026-10-28): Turf Monster's own form stays one line, and Two lines is offered beside it.
  test "Turf Monster's Stacked tab offers One line and Two lines, and draws the two-line logo when asked" do
    log_in_as(@admin)
    get logo_brand_path("turf", type: "stacked")
    assert_response :success
    assert_equal [%w[one_line One\ line true], %w[two_line Two\ lines]],
                 css_select("[data-test='form-option']").map { |a| [a["data-form"], a.text.strip, a["aria-current"]].compact }
    assert_select "a[data-test='form-option'][data-form='two_line'][href=?]", logo_brand_path("turf", type: "stacked", form: "two_line")

    get logo_brand_path("turf", type: "stacked", form: "two_line")
    assert_response :success
    assert_select "a[data-test='form-option'][data-form='two_line'][aria-current='true']"
    assert_select "img[data-test='logo-image'][src*='form=two_line']", 2
    get stacked_logo_path("turf", form: "two_line", tone: "dark")
    assert_response :success
    two_line = Logos::StackedLogo.new("turf").layout(form: :two_line, tone: :dark, text: :first)
    assert_match(/viewBox="0 0 #{format('%.2f', two_line.width)} #{format('%.2f', two_line.height)}"/, response.body, "the two-line drawing's box")
  end

  test "the Stacked Logo tab shows one logo in the kit's text version, with and without guides" do
    log_in_as(@admin)
    %w[industries welding turf].each do |brand|
      get logo_brand_path(brand, type: "stacked")
      assert_response :success
      assert_equal [BrandKit.defaults(brand, :stacked)[:text].to_s], css_select("[data-test='logo-example']").map { |example| example["data-text"] }
      assert_examples themed(brand, :stacked)
      assert_select "img[data-test='logo-image'][alt*=' stacked logo, '][src^=?]", stacked_logo_path(brand), 2
      assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path(brand, type: "stacked", guides: 1), text: "Show"

      get logo_brand_path(brand, type: "stacked", guides: 1)
      assert_response :success
      assert_examples themed(brand, :stacked, guides: true)
      assert_select "img[data-test='logo-image'][alt$='construction guides'][src*='guides=1']", 2
      assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path(brand, type: "stacked"), text: "Hide"
    end
  end

  test "the Icon tab shows the icon alone with a download and a copy, and no rule or guides: only Save as default" do
    log_in_as(@admin)
    [nil, *CONTEXTS].each do |context|
      get logo_brand_path("welding", { type: "icon", context:, guides: 1, rule: 3 }.compact)
      assert_response :success
      tones = context == "watermark" ? %w[watermark] : %w[light dark]
      assert_examples tones.flat_map { |tone| variants("welding", :icon, tone: tone.to_sym) }, examples: 1
      tones.each do |tone|
        original = { colouring: tone == "watermark" ? "alt" : "original" }
        assert_select "img[data-test='logo-image'][alt=?][src=?]", "Commercial Welding v1 icon, #{tone}#{', original colouring' if tone != 'watermark'}",
                      icon_logo_path("welding", tone:, **original)
        assert_includes download_urls, icon_logo_path("welding", tone:, **original, download: 1)
      end
      assert_select "[data-test='logo-frame']", 1
      assert_select "[data-test='logo-plate']", 0
      assert_select "[data-test='logo-example'] h2", 0
      assert_select "[data-test='guides-toggle'], [data-test='rule-control'], [data-test='guides-sentence']", 0
      assert_equal %w[colouring-option colouring-option kit-save-default], css_select("[data-test='logo-controls'] .btn").map { |control| control["data-test"] }
      assert_select "[data-test='logo-control-card'] [data-test='edit-jump']", 1
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
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf", type: "stacked", context: "watermark", rule: 3), text: "Hide"
    assert_select "a[data-test='logos-crumb'][href=?]", logos_path(context: "watermark"), text: "Logos"

    # Light and dark are the hub's theme, which every page keeps already: a link never carries them.
    get logo_brand_path("turf", context: "dark", guides: 1)
    assert_equal [logo_brand_path("turf", rule: 3, guides: 1), logo_brand_path("turf", guides: 1), logo_brand_path("turf", rule: 6, guides: 1)],
                 css_select("a[data-test='rule-option']").map { |option| option["href"] }
    assert_equal [%w[guides 1]], css_select("form[data-test='context-form'] input[type='hidden']").map { |i| [i["name"], i["value"]] }
    assert_select "a[data-test='logos-crumb'][href=?]", logos_path
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf"), text: "Hide"

    # The defaults (Navbar Logo, the theme's logos, rule of 4, guides off) are left out, even when named.
    get logo_brand_path("turf", type: "navbar", context: "light", rule: 4, guides: 0)
    assert_response :success
    assert_select "a[data-test='logo-tab'][data-type='navbar'][href=?]", logo_brand_path("turf")
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("turf", guides: 1), text: "Show"
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

  # The brand's note on how its art was derived went with the page's words (task brand-page-split-layout).
  test "each added brand's page names it on every tab" do
    log_in_as(@admin)
    names = { "turf" => "Turf Monster", "welding" => "Commercial Welding v1", "welding_v2" => "Commercial Welding v2" }
    names.to_a.product(%w[icon navbar stacked]).each do |(brand, name), type|
      get logo_brand_path(brand, type:)
      assert_response :success
      assert_select "h1", name
      alts = css_select("[data-test='logo-image']").map { |img| img["alt"] }
      assert_equal 2, alts.uniq.size, "the one logo in light and in dark"
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
        assert_select "select#logo-context[name='context'][autocomplete='off']:not([onchange])", 1, "autocomplete off: the browser must not restore a stale value over the theme after Back"
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

      assert_select "[data-test='logo-plate']", 0
      if context == "watermark"
        assert_examples variants("industries", type.to_sym, tone: :watermark)
        assert_select "[data-test='logo-themed']", 0
      else
        assert_examples themed("industries", type.to_sym)
        assert_themed_pairs(1)
        assert_select "img[data-test='logo-image'][src*='tone=watermark']", 0
      end
    end
  end

  # The watermark's explanation went with the page's words (task brand-page-split-layout); the page still draws it.
  test "the watermark context draws one logo per tab, with no notes" do
    log_in_as(@admin)
    %w[turf welding studio industries].each do |brand|
      %w[navbar stacked].each do |type|
        get logo_brand_path(brand, type:, context: "watermark")
        assert_response :success
        assert_select "[data-test='logo-example']", 1, "one logo per tab (task logo-download-card)"
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

  test "Commercial Welding is served in its own lettering, with the two-colour helmet on dark" do
    log_in_as(@admin)
    lettering = Logos::NavbarLogo.letterings.fetch("welding").fetch("words").values.flatten.map { |letter| letter["d"] }
    icons = Logos::NavbarLogo.icons
    { "light" => "welding", "watermark" => "welding_mono", "dark" => "welding_original" }.each do |tone, icon|
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
    assert_select "a[data-test='guides-toggle'].btn-neutral[href=?]", logo_brand_path("industries", guides: 1), text: "Show"
    assert_select "img[data-test='logo-image'][src*='guides=1']", 0

    get logo_brand_path("industries", guides: 1, rule: 3)
    assert_response :success
    assert_select "a[data-test='guides-toggle'].btn-primary[href=?]", logo_brand_path("industries", rule: 3), text: "Hide"
    assert_examples themed("industries", :navbar, rule: 3, guides: true)
    assert_select "img[data-test='logo-image'][src*='guides=1'][alt$='construction guides']", 2
    assert_select "a[data-test='logo-download'][href*='guides=1']", 1
    assert_equal 3, download_urls.count { |url| url.include?("guides=1") }, "every tone's download is the guide drawing as shown"

    # A guide drawing fits its frame (max-width) down to a least width of its own, where its frame starts to scroll.
    # One frame holds both tones' drawings; its name is the drawing's, without the tone.
    assert_select "[data-test='logo-frame'].overflow-x-auto[role='group'][aria-label^='Guide drawing: McRitchie Industries navbar logo']", 1
    assert_equal ["Guide drawing: McRitchie Industries navbar logo, rule of 3, second word leads, original colouring, construction guides"],
                 css_select("[data-test='logo-frame']").first(1).map { |frame| frame["aria-label"] }
    # A tab stop as served (so it works with JavaScript off); scroll_tab_stop.js drops the tabindex wherever the drawing fits.
    assert_select "[data-test='logo-frame'][tabindex='0'][data-scroll-tab-stop]", 1
    assert_select "[data-test='logo-frame'][x-data], [data-test='logo-frame'][x-init]", 0
    styles = css_select("[data-test='logo-frame'] img.max-w-full").map { |img| img["style"] }
    assert_equal 2, styles.size
    styles.each { |style| assert_match(/\Amax-height: 132px; min-width: [5-6]\d\dpx\z/, style) }
    get logo_brand_path("industries", type: "stacked", guides: 1)
    assert_equal ["max-height: 280px; min-width: 483px"],
                 css_select("[data-test='logo-frame'].overflow-x-auto [data-tone='light'] img.max-w-full").map { |img| img["style"] }
    # Capped near the normal card's height, unless the labels would fall below their least size: the tagline form's
    # drawing then takes the height its least width gives it, not more.
    get logo_brand_path("welding", type: "stacked", form: "tagline", guides: 1)
    style = css_select("[data-test='logo-frame'] [data-tone='light'] img").first["style"]
    height = style[/max-height: (\d+)px/, 1].to_i
    assert_operator height, :>, 280
    assert_operator height, :<, 540
    get logo_brand_path("industries", type: "stacked")
    assert_select "[data-test='logo-frame'].overflow-x-auto, [data-test='logo-frame'][tabindex]", 0
    assert_select "[data-test='logo-frame'] img[style='max-height: 240px'].max-w-full", 2
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

    # Item 4d (task navbar-spacing-and-rotated-guides): the endpoint and its filenames take the rule of 6.
    get navbar_logo_path("industries", rule: 6, text: "second", tone: "light", download: 1)
    assert_response :success
    assert_equal Logos::NavbarLogo.new("industries").svg(rule: 6, text: :second, tone: :light), response.body
    assert_match(/\Aattachment; filename="industries-navbar-rule6-second-light\.svg"/, response.headers["Content-Disposition"])
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
      logo_brand_path("industries", type: "") => /unknown type ""/, logo_brand_path("industries", rule: 5) => /unknown rule "5": expected one of 3, 4, 6/,
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
      "welding" => [%w[two_line tagline], ["Two lines", "With tagline"]], "turf" => [%w[one_line two_line], ["One line", "Two lines"]] }.each do |brand, (forms, words)|
      get logo_brand_path(brand, type: "stacked")
      assert_response :success
      assert_select "[data-test='form-control'][role='group'][aria-label='Form']", 1
      options = css_select("a[data-test='form-option']")
      assert_equal forms, options.map { |option| option["data-form"] }, brand
      assert_equal words, options.map { |option| option.text.strip }, brand
      assert_equal [forms.first], css_select("a[data-test='form-option'][aria-current='true']").map { |option| option["data-form"] }, "#{brand}: its own form"
      assert_equal logo_brand_path(brand, type: "stacked"), options.first["href"], "#{brand}: its own form is the default, left out"
      if brand == "turf"
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
    assert_examples themed("welding", :stacked, form: :tagline, guides: true)
    assert_equal ["tagline"], css_select("a[data-test='form-option'][aria-current='true']").map { |option| option["data-form"] }
    assert_equal %w[welding-stacked-tagline-homogeneous-light-original-guides.svg],
                 variants("welding", :stacked, form: :tagline, guides: true).map(&:filename), "the file the Download link above serves"
    assert_select "img[data-test='logo-image'][alt^='Commercial Welding v1 stacked logo, with tagline, ']", 2

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
    assert_select "a[data-test='guides-toggle'][href=?]", logo_brand_path("studio", type: "stacked", context: "watermark", form: "tagline"), text: "Hide"
    assert_equal [logo_brand_path("studio", type: "stacked", context: "watermark", guides: 1), logo_brand_path("studio", type: "stacked", context: "watermark", form: "tagline", guides: 1)],
                 css_select("a[data-test='form-option']").map { |option| option["href"] }

    get logo_brand_path("studio", form: "tagline", rule: 3)
    assert_equal [logo_brand_path("studio", form: "tagline", rule: 3), logo_brand_path("studio", form: "tagline"), logo_brand_path("studio", form: "tagline", rule: 6)],
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

  # Task welding-llc-and-v2-helmet (Alex McRitchie's item 5): v1 and v2 side by side, so his tweaks compare with the original.
  test "Commercial Welding v1 and v2 sit side by side in the table, each with its own name and helmet" do
    log_in_as(@admin)
    get logos_path
    assert_response :success
    rows = css_select("[data-test='logo-brand-row']").map { |row| row["data-brand"] }
    assert_equal rows.index("welding") + 1, rows.index("welding_v2"), "v2 is the row after v1"
    { "welding" => "Commercial Welding v1", "welding_v2" => "Commercial Welding v2" }.each do |brand, name|
      assert_select "[data-test='logo-brand-row'][data-brand='#{brand}'] th a[href=?]", logo_brand_path(brand), text: name
    end

    words = Logos::NavbarLogo.letterings.fetch("welding").fetch("words")
    { "welding" => [%w[COMMERCIAL WELDING LLC], "welding"], "welding_v2" => [%w[COMMERCIAL WELDING], "welding_v2"] }.each do |brand, (name, icon)|
      get navbar_logo_path(brand, rule: 3, guides: 1)
      assert_response :success
      logo = Nokogiri::XML(response.body).remove_namespaces!.css("svg > path")
      icon_paths, letters = logo.partition { |path| path["transform"].nil? }
      assert_equal words.values_at(*name).flatten.map { |letter| letter["d"] }, letters.map { |path| path["d"] }, "#{brand} reads #{name.join(' ')}"
      helmet = Nokogiri::XML(response.body).remove_namespaces!.css("svg > g:not([class]) path").map { |path| path["d"] }
      assert_equal Logos::NavbarLogo.icons.fetch(icon).fetch("layers").map { |layer| layer["d"] }, helmet, "#{brand}'s own helmet"
      assert icon_paths.empty?, "the helmet is inside its scale group"
    end
  end

  test "Commercial Welding v2's brand page draws every type, and its guide drawings, from its own data" do
    log_in_as(@admin)
    get logo_brand_path("welding_v2", type: "icon")
    assert_response :success
    assert_select "h1", "Commercial Welding v2"
    assert_examples %i[light dark].flat_map { |tone| variants("welding_v2", :icon, tone:) }, examples: 1
    get logo_brand_path("welding_v2", type: "navbar", rule: 3, guides: 1)
    assert_response :success
    assert_examples themed("welding_v2", :navbar, rule: 3, guides: true)
    get logo_brand_path("welding_v2", type: "stacked", form: "tagline", guides: 1)
    assert_response :success
    assert_examples themed("welding_v2", :stacked, form: :tagline, guides: true)
  end

  # Task stacked-rule-of-three: the Stacked tab's Proportion control, carried in the URL like every other choice.
  test "the Stacked tab offers 3-2-1 and the rule of three, and the rule of three is drawn, named and carried" do
    log_in_as(@admin)
    get logo_brand_path("welding_v2", type: "stacked")
    assert_response :success
    assert_select "[data-test='proportion-control'][role='group'][aria-label='Proportion']", 1
    options = css_select("a[data-test='proportion-option']")
    assert_equal ["3-2-1", "Rule of three"], options.map { |option| option.text.strip }
    assert_equal ["three_two_one"], css_select("a[data-test='proportion-option'][aria-current='true']").map { |option| option["data-proportion"] }
    assert_equal [logo_brand_path("welding_v2", type: "stacked"), logo_brand_path("welding_v2", type: "stacked", proportion: "rule_of_three")],
                 options.map { |option| option["href"] }, "3-2-1 is the default, left out"

    get logo_brand_path("welding_v2", type: "stacked", proportion: "rule_of_three", form: "tagline", guides: 1)
    assert_response :success
    assert_examples themed("welding_v2", :stacked, form: :tagline, proportion: :rule_of_three, guides: true)
    assert_equal ["rule_of_three"], css_select("a[data-test='proportion-option'][aria-current='true']").map { |option| option["data-proportion"] }
    assert_select "img[data-test='logo-image'][alt*=', with tagline, rule of three, ']", 2
    kept = { type: "stacked", form: "tagline", proportion: "rule_of_three", guides: 1 }
    assert_equal logo_brand_path("welding_v2", kept.except(:form)), css_select("a[data-test='form-option'][data-form='two_line']").first["href"], "the form keeps the proportion"
    assert_equal logo_brand_path("welding_v2", kept.except(:type)), css_select("a[data-test='logo-tab'][data-type='navbar']").first["href"], "the other tabs carry it back"
    saved = css_select("form[data-test='kit-save-default-form'] input[type='hidden']").to_h { |i| [i["name"], i["value"]] }
    assert_equal %w[tagline rule_of_three], saved.values_at("form", "proportion"), "Save as default sends the proportion"

    get logo_brand_path("welding_v2", type: "stacked", proportion: "golden")
    assert_response :unprocessable_content
    assert_equal 'unknown proportion "golden": expected one of three_two_one, rule_of_three', response.body
  end

  test "a kit saved in the rule of three opens on it, and 3-2-1 is then the one the URL names" do
    log_in_as(@admin)
    patch brand_kit_choice_path("welding_v2"), params: { type: "stacked", form: "two_line", proportion: "rule_of_three", text: "first", colouring: "original" }
    assert_equal "rule_of_three", BrandKit.find_by!(brand: "welding_v2").stacked_choice["proportion"]
    get logo_brand_path("welding_v2", type: "stacked")
    assert_response :success
    assert_equal ["rule_of_three"], css_select("a[data-test='proportion-option'][aria-current='true']").map { |option| option["data-proportion"] }
    assert_select "[data-test='kit-default-state'][data-state='shown']"
    assert_equal [logo_brand_path("welding_v2", type: "stacked", proportion: "three_two_one"), logo_brand_path("welding_v2", type: "stacked")],
                 css_select("a[data-test='proportion-option']").map { |option| option["href"] }
    get logo_brand_path("welding_v2", type: "stacked", proportion: "three_two_one")
    assert_select "[data-test='kit-default-state'][data-state='changed']"

    get stacked_logo_path("welding_v2", tone: "light")
    assert_equal "kit", response.headers["X-Logo-Source"]
    assert_equal Logos::StackedLogo.new("welding_v2").svg(proportion: :rule_of_three, text: :first, colouring: :original), response.body
  end
end
