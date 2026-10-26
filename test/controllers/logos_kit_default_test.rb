# frozen_string_literal: true

require "test_helper"

# [component] The SVG routes default to the KIT (task kit-export-and-clear-lens; Alex McRitchie 2026-10-12 00:55: his Commercial
# Welding site drew "COMMERCIAL" white and "WELDING" orange, not his saved kit Navbar). Asked with no choice params,
# /icon, /navbar and /stacked answer with the brand's saved kit logo in the asked tone; any choice param wins; a brand
# with nothing saved answers byte for byte as before.
class LogosKitDefaultTest < ActionDispatch::IntegrationTest
  Variant = Logos::Variant

  setup { log_in_as(users(:alex)) }

  def save(brand, type, params) = BrandKit.for(brand).save_choice(type, params, by: users(:alex).email)
  def kit(brand) = BrandKit.find_by!(brand:)
  def before(brand, type, params = {}) = Variant.parse(Variant.logo(brand, type), params, type:).svg

  test "a brand with nothing saved draws exactly as before, every type and tone" do
    BrandKit.where(brand: "welding_v2").delete_all
    %i[icon navbar stacked].product([nil, "light", "dark", "watermark"]).each do |type, tone|
      params = { tone: }.compact
      get public_send(:"#{type}_logo_path", "welding_v2", params)
      assert_response :success
      assert_equal before("welding_v2", type, params), response.body, "#{type} #{tone.inspect}"
      assert_equal "params", response.headers["X-Logo-Source"]
    end
  end

  test "with a saved Navbar, /navbar with no params is the kit's navbar in the asked tone" do
    save("welding_v2", :navbar, { rule: "4", text: "homogeneous", colouring: "original" })
    { nil => :light, "light" => :light, "dark" => :dark, "watermark" => :watermark }.each do |tone, drawn|
      get navbar_logo_path("welding_v2", { tone: }.compact)
      assert_response :success
      assert_equal "kit", response.headers["X-Logo-Source"], tone.inspect
      assert_equal kit("welding_v2").variant(:navbar, tone: drawn).svg, response.body, tone.inspect
    end
    get navbar_logo_path("welding_v2", tone: "dark")
    refute_equal before("welding_v2", :navbar, { tone: "dark" }), response.body, "the kit differs from the route's old default (rule 3, Alt)"
    get navbar_logo_path("welding_v2", tone: "dark", download: 1)
    assert_equal 'attachment; filename="welding_v2-navbar-rule4-homogeneous-dark-original.svg"; ' \
                 "filename*=UTF-8''welding_v2-navbar-rule4-homogeneous-dark-original.svg", response.headers["Content-Disposition"]
  end

  # Alex McRitchie's own kit: Original, homogeneous: the words are solid white on a dark page, the helmet is the Original's.
  test "the saved Original homogeneous navbar draws solid white words and the Original helmet on dark" do
    save("welding_v2", :navbar, { rule: "4", text: "homogeneous", colouring: "original" })
    get navbar_logo_path("welding_v2", tone: "dark")
    fills = response.body.scan(/fill="(#\h{6})"/).flatten.uniq
    assert_includes fills, "#FFFFFF"
    refute_includes fills, "#F08A5A", "no ember word: the Alt dark highlight"
    assert_includes response.body, Logos::NavbarLogo.icons.fetch("welding_v2_original").fetch("layers").last.fetch("d"), "the Original's spark"
  end

  test "any choice param wins over the kit" do
    save("welding_v2", :navbar, { rule: "4", text: "homogeneous", colouring: "original" })
    save("welding_v2", :icon, { colouring: "original" })
    [{ rule: "3" }, { text: "first" }, { colouring: "alt" }, { guides: "0" }, { first_colour: "D7602E" }].each do |extra|
      get navbar_logo_path("welding_v2", extra.merge(tone: "dark"))
      assert_equal "params", response.headers["X-Logo-Source"], extra.inspect
      assert_equal before("welding_v2", :navbar, extra.merge(tone: "dark")), response.body, extra.inspect
    end
    get icon_logo_path("welding_v2", colouring: "alt", tone: "light")
    assert_equal before("welding_v2", :icon, { colouring: "alt", tone: "light" }), response.body
  end

  test "the icon and stacked routes take the kit too, and the kit icon is the one every logo draws" do
    save("welding_v2", :icon, { colouring: "alt", icon_colour: "D7602E" })
    get icon_logo_path("welding_v2", tone: "light")
    assert_equal "kit", response.headers["X-Logo-Source"]
    assert_equal kit("welding_v2").variant(:icon, tone: :light).svg, response.body
    assert_includes response.body, "#D7602E"
    get stacked_logo_path("welding_v2")
    assert_equal "kit", response.headers["X-Logo-Source"], "a kit with only an icon saved still answers the stacked route: its default, with the kit icon"
    assert_equal kit("welding_v2").variant(:stacked, tone: :light).svg, response.body
  end

  test "a kit the brand's data can no longer draw answers as before, never a 422" do
    save("welding_v2", :navbar, { rule: "4", text: "homogeneous", colouring: "original" })
    kit("welding_v2").update_column(:navbar_choice, { "rule" => 9, "text" => "homogeneous" })
    get navbar_logo_path("welding_v2", tone: "dark")
    assert_response :success
    assert_equal "params", response.headers["X-Logo-Source"]
    assert_equal before("welding_v2", :navbar, { tone: "dark" }), response.body
  end

  test "a bad tone is still refused with or without a kit" do
    save("welding_v2", :navbar, { rule: "4", text: "homogeneous", colouring: "original" })
    get navbar_logo_path("welding_v2", tone: "sepia")
    assert_response :unprocessable_content
  end
end
