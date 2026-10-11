# frozen_string_literal: true

require "test_helper"

# [component] Logo COLOURINGS through the routes (task logo-original-and-alt): every SVG endpoint takes
# ?colouring=original|alt (Alt unless asked, so every existing URL serves what it served), names an Original's file
# -original, and refuses an Original of a brand that has none.
class LogosColouringTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def disposition = response.headers["Content-Disposition"]

  test "every SVG endpoint serves the Original when asked, as a file named -original" do
    navbar = Logos::NavbarLogo.new("welding")
    stacked = Logos::StackedLogo.new("welding")
    {
      icon_logo_path("welding", tone: "dark", colouring: "original", download: 1) =>
        [navbar.icon_svg(tone: :dark, colouring: :original), "welding-icon-dark-original.svg"],
      navbar_logo_path("welding", rule: 3, text: "first", tone: "light", colouring: "original", download: 1) =>
        [navbar.svg(rule: 3, text: :first, tone: :light, colouring: :original), "welding-navbar-rule3-first-light-original.svg"],
      stacked_logo_path("welding", form: "tagline", text: "first", tone: "dark", colouring: "original", download: 1) =>
        [stacked.svg(form: :tagline, text: :first, tone: :dark, colouring: :original), "welding-stacked-tagline-first-dark-original.svg"]
    }.each do |path, (svg, filename)|
      get path
      assert_response :success
      assert_equal svg, response.body, path
      assert_match(/\Aattachment; filename="#{Regexp.escape(filename)}"/, disposition)
    end
  end

  test "an endpoint draws Alt unless asked, exactly as before, and colouring=alt is the same file" do
    alt = Logos::NavbarLogo.new("welding").svg(rule: 4, text: :second, tone: :dark)
    [{}, { colouring: "alt" }].each do |more|
      get navbar_logo_path("welding", { rule: 4, text: "second", tone: "dark" }.merge(more))
      assert_equal alt, response.body
      assert_match(/filename="welding-navbar-rule4-second-dark\.svg"/, disposition)
    end
  end

  test "a watermark has no colouring: asking for the Original serves the one-colour watermark" do
    get icon_logo_path("welding", tone: "watermark", colouring: "original")
    assert_response :success
    assert_equal Logos::NavbarLogo.new("welding").icon_svg(tone: :watermark), response.body
    assert_match(/filename="welding-icon-watermark\.svg"/, disposition)
  end

  test "an Original of a brand with none, or an unknown colouring, is a 422 in plain text" do
    get navbar_logo_path("studio", colouring: "original")
    assert_response :unprocessable_content
    assert_equal "brand studio: it has no original colouring (its logo is solid colour), so only alt", response.body
    get icon_logo_path("welding", colouring: "sepia")
    assert_response :unprocessable_content
    assert_match(/unknown colouring "sepia": expected one of original, alt/, response.body)
  end
end
