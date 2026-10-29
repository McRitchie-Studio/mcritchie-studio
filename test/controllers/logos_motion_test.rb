# frozen_string_literal: true

require "test_helper"

# [component] The brand page's Motion tab (task logo-motion-presets): the tab beside Icon, Navbar Logo and Stacked Logo,
# the presets the brand can play, the logo it plays (the kit's own, fetched from its SVG route), Save as default and
# Clear saved motion, the kit status line, and the plain-text 422 for a preset the brand cannot play.
class LogosMotionTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def sources = JSON.parse(css_select("[data-test='motion-player']").first["data-sources"])
  def player = css_select("[data-test='motion-player']").first

  test "every tab links the Motion tab, and the Motion tab opens on the first preset on the Stacked Logo" do
    get logo_brand_path("turf", type: "stacked")
    assert_select "a[data-test='logo-tab'][data-type='motion'][href=?]", logo_brand_path("turf", type: "motion"), text: "Motion"

    get logo_brand_path("turf", type: "motion")
    assert_response :success
    assert_select "a[data-test='logo-tab'][data-type='motion'][aria-current='page']"
    assert_select "a[data-test='logo-tab'][data-type='navbar']:not([aria-current])"
    assert_select "[data-test='logo-type'][data-type='motion']"
    assert_equal "pop_slide", player["data-preset"]
    assert_equal "stacked", player["data-logo"]
    assert_select "a[data-test='motion-preset']", 8
    assert_select "a[data-test='motion-preset'][aria-current='true']", text: /Pop and slide/
    assert_select "a[data-test='motion-logo-option'][data-logo='stacked'][aria-current='true']"
    assert_select "[data-test='motion-default-state'][data-state='none']"
    assert_select "[data-test='motion-still'] img", minimum: 1
    # No explanatory text on the brand page (task brand-page-split-layout): only the kit-default line.
    assert_select "[data-test='motion-preset-note']", 0
    assert_select "[data-test='logo-control-card'] p", 1
    assert_select "[data-test='logo-control-card'] p[data-test='motion-default-state']", 1
    refute_includes response.body, "It plays the kit's"
    assert_select "[data-test='motion-presets'] > span", "Preset"
  end

  test "the stage plays the kit's own logo: each tone's SVG route, and the brand's accent" do
    get logo_brand_path("welding_v2", type: "motion", preset: "particle_resolve", logo: "navbar")
    assert_equal %w[dark light], sources.keys.sort
    kit = BrandKit.for("welding_v2")
    %w[light dark].each do |tone|
      assert_equal logo_asset_path_for(kit.variant(:navbar, tone: tone.to_sym)), sources.dig(tone, "url")
      assert_nil sources.dig(tone, "thin_url"), "only Weight flick needs the thin logo"
    end
    assert_equal "#F08A5A", sources.dig("dark", "accent")
    get sources.dig("dark", "url")
    assert_response :success
    assert_equal kit.variant(:navbar, tone: :dark).svg, response.body
  end

  test "Weight flick also fetches the same logo at its lightest weight; a traced brand is not offered it and is refused it" do
    get logo_brand_path("studio", type: "motion", preset: "weight_flick")
    thin = sources.dig("dark", "thin_url")
    assert_includes thin, "first_weight=300"
    assert_includes thin, "ending_weight=300"
    get thin
    assert_response :success
    assert_match(/\A<svg/, response.body)

    get logo_brand_path("welding", type: "motion")
    assert_select "a[data-test='motion-preset']", 7
    assert_select "a[data-test='motion-preset'][data-preset='weight_flick']", 0
    assert_select "[data-test='motion-weights-note']", 0, "no explanatory text on the brand page"
    get logo_brand_path("welding", type: "motion", preset: "weight_flick")
    assert_response :unprocessable_content
    assert_match(/needs lettering with weights/, response.body)
  end

  test "Save as default stores the preset and logo, the tab opens on it, the status line says so, and Clear takes it away" do
    get logo_brand_path("industries", type: "motion", preset: "match_cut", logo: "navbar")
    form = css_select("form[data-test='motion-save-form']").first
    fields = form.css("input[type=hidden]").to_h { |input| [input["name"], input["value"]] }.except("_method", "authenticity_token")
    assert_equal({ "type" => "motion", "preset" => "match_cut", "logo" => "navbar" }, fields)

    patch brand_kit_choice_path("industries"), params: fields
    assert_redirected_to logo_brand_path("industries", type: "motion", anchor: "motion")
    assert_equal({ "preset" => "match_cut", "logo" => "navbar" }, BrandKit.find_by(brand: "industries").motion_choice)
    follow_redirect!
    assert_select "[data-test='kit-status']", /Kit: saved .* · motion: Match-cut build on the Navbar Logo/
    assert_equal "match_cut", player["data-preset"]
    assert_equal "navbar", player["data-logo"]
    assert_select "[data-test='motion-default-state'][data-state='shown']"
    assert_select "input[data-test='motion-save'][disabled]"

    get logo_brand_path("industries", type: "motion", preset: "pop_slide")
    assert_select "[data-test='motion-default-state'][data-state='changed']", /The kit's motion is Match-cut build on the Navbar Logo/

    delete brand_kit_choice_path("industries"), params: { type: "motion" }
    assert_redirected_to logo_brand_path("industries", type: "motion", anchor: "motion")
    assert_nil BrandKit.find_by(brand: "industries").motion_choice
  end

  test "a refused motion save is a plain-text 422 and stores nothing" do
    patch brand_kit_choice_path("turf"), params: { type: "motion", preset: "spin", logo: "stacked" }
    assert_response :unprocessable_content
    assert_match(/unknown motion preset "spin"/, response.body)
    assert_nil BrandKit.find_by(brand: "turf")
  end

  private

  def logo_asset_path_for(variant) = public_send(:"#{variant.type}_logo_path", variant.logo.brand, variant.params)
end
