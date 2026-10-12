# frozen_string_literal: true

require "test_helper"

# [integration] A saved kit icon reaches every logo's SVG (task kit-icon-atomic-unit). Alex's case, 2026-10-11 19:23:
# on Commercial Welding v2, a Stacked Logo saved in Alt and the Icon saved in Original. The table row and both tabs
# then draw the Original helmet everywhere: each SVG served is, byte for byte, the library's drawing with Alt words
# (or the tab's own) and the Original icon.
class KitIconRoundTripTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def form_fields(form) = form.css("input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
  def query(src) = Rack::Utils.parse_query(URI(src).query.to_s)

  def save_default(**page)
    get logo_brand_path("welding_v2", page)
    form = css_select("form[data-test='kit-save-default-form']").first
    patch form["action"], params: form_fields(form)
    assert_response :redirect
  end

  def svg_at(src)
    get src
    assert_response :success
    response.body
  end

  test "Stacked saved in Alt and the Icon in Original: the table row and both tabs draw the Original helmet" do
    save_default(type: "stacked", colouring: "alt")
    save_default(type: "icon", colouring: "original")
    navbar = Logos::NavbarLogo.new("welding_v2")
    stacked = Logos::StackedLogo.new("welding_v2")

    get logos_path
    cluster = css_select("[data-test='logo-cluster'][data-brand='welding_v2'] img").to_h { |img| [[img.ancestors("[data-type]").first["data-type"], query(img["src"])["tone"]], img["src"]] }
    assert_equal 6, cluster.size
    %w[light dark].each do |tone|
      assert_equal navbar.icon_svg(tone: tone.to_sym, colouring: :original), svg_at(cluster.fetch(["icon", tone]))
      assert_equal stacked.svg(text: :first, tone: tone.to_sym, form: stacked.form, colouring: :alt, icon_colouring: :original),
                   svg_at(cluster.fetch(["stacked", tone])), "the saved Alt stacked, with the Original helmet (#{tone})"
      assert_equal navbar.svg(rule: 4, text: :second, tone: tone.to_sym, colouring: :original), svg_at(cluster.fetch(["navbar", tone]))
    end

    get logo_brand_path("welding_v2", type: "stacked")
    srcs = css_select("[data-test='logo-type'] img[data-test='logo-image']").map { |img| img["src"] }
    assert_equal 6, srcs.size
    srcs.each do |src|
      params = query(src)
      expected = stacked.svg(text: params["text"].to_sym, tone: params["tone"].to_sym, form: stacked.form, colouring: :alt, icon_colouring: :original)
      assert_equal expected, svg_at(src), src
    end

    get logo_brand_path("welding_v2", colouring: "alt")
    css_select("[data-test='logo-type'] img[data-test='logo-image']").map { |img| img["src"] }.each do |src|
      params = query(src)
      assert_equal navbar.svg(rule: 4, text: params["text"].to_sym, tone: params["tone"].to_sym, colouring: :alt, icon_colouring: :original), svg_at(src)
    end
  end

  test "changing the kit icon changes every logo at once" do
    save_default(type: "icon", colouring: "original")
    save_default(type: "icon", colouring: "alt", icon_colour: "D7602E")
    get logos_path
    srcs = css_select("[data-test='logo-cluster'][data-brand='welding_v2'] img").map { |img| query(img["src"]) }
    assert_equal 6, srcs.size
    assert(srcs.all? { |src| src["icon_colour"] == "D7602E" && src["icon_colouring"].in?([nil, "alt"]) }, srcs.inspect)
    assert_includes svg_at(css_select("[data-test='logo-cluster'][data-brand='welding_v2'] [data-type='stacked'] img").first["src"]), 'fill="#D7602E"'
  end
end
