# frozen_string_literal: true

require "test_helper"

# [component] Each brand's Google marketing kit on /logos (tasks marketing-kit-on-logos, logos-table-columns-tidy): under
# each brand's name every brand has one Google kit chip: the Drive mark, the account that owns the kit and a check
# (Up to date) or an amber triangle (Kit changed), opening its Drive folder in a new tab; or a hollow "No Google kit".
# The accessible name carries the status, the title the dates. One query reads every brand's.
class MarketingKitStatusTest < ActionDispatch::IntegrationTest
  URL = "https://drive.google.com/drive/folders/cw123"

  setup { log_in_as(users(:alex)) }

  def chip(brand) = css_select("[data-test='kit-chip'][data-kind='google'][data-brand='#{brand}']").first
  def mark(node) = node.at_css("[data-test='kit-chip-mark']")

  test "every brand shows its Google kit chip: Up to date, Kit changed or No Google kit" do
    BrandKit.create!(brand: "welding_v2", saved_at: Time.utc(2026, 10, 20))
    BrandKit.create!(brand: "studio", saved_at: Time.utc(2026, 10, 22))
    BrandMarketingKit.create!(brand: "welding_v2", drive_url: URL, owner: "team@commercialwelding.llc",
                              published_at: Time.utc(2026, 10, 21), published_saved_at: Time.utc(2026, 10, 20))
    BrandMarketingKit.create!(brand: "studio", drive_url: "#{URL}s", published_at: Time.utc(2026, 10, 21))
    get logos_path
    assert_response :success

    cw = chip("welding_v2")
    assert_equal "team@commercialwelding.llc", cw.at_css("[data-test='kit-chip-name']").text
    assert_equal "Google Drive", cw.css("svg[data-test='google-drive-icon']").first["aria-label"]
    assert_equal ["current", "done"], [cw["data-status"], mark(cw)["data-mark"]]
    assert_includes mark(cw)["class"].split, "text-success-ink"
    assert_equal "Google kit team@commercialwelding.llc: Up to date", cw["aria-label"]
    assert_equal "Google kit team@commercialwelding.llc: Up to date. Kit saved Oct 20, 2026; published Oct 21, 2026 (kit of Oct 20, 2026)", cw["title"]
    assert_equal ["a", URL, "_blank", "noopener"], [cw.name, cw["href"], cw["target"], cw["rel"]]

    studio = chip("studio")
    assert_equal "Google kit", studio.at_css("[data-test='kit-chip-name']").text, "no owner recorded: the chip says Google kit"
    assert_equal ["Google kit: Kit changed", "changed"], [studio["aria-label"], mark(studio)["data-mark"]]
    assert_includes mark(studio)["class"].split, "text-warning-ink", "Kit changed is amber"

    none = chip("turf")
    assert_equal ["span", "none", "No Google kit", "none"], [none.name, none["data-status"], none["aria-label"], mark(none)["data-mark"]]
    assert_equal "No Google kit", none.text.squish
    assert_equal Logos::NavbarLogo.brands.size, css_select("[data-test='kit-chip'][data-kind='google']").size, "one chip per brand"
    assert_select "[data-brand='welding_v2'] th [data-test='logo-kit-apps'] [data-test='kit-chip'][data-kind='google']", 1,
                  "the Google kit chip sits under the brand's name"
  end

  test "the table reads every brand's Google kit in one query" do
    %w[studio turf welding].each { |brand| BrandMarketingKit.create!(brand:, drive_url: URL) }
    get logos_path
    counted = []
    counter = ->(*, payload) { counted << payload[:sql] if payload[:sql].include?("brand_marketing_kits") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get logos_path }
    assert_equal 1, counted.size, counted.join("\n")
  end
end
