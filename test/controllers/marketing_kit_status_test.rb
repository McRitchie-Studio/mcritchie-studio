# frozen_string_literal: true

require "test_helper"

# [component] Each brand's Google marketing kit on /logos (task marketing-kit-on-logos): under the app lines, every
# brand shows "📁 Google kit", Up to date (green) or Kit changed (amber) and an Open link to its Drive folder, or a muted
# "No Google kit"; the title gives the workspace and dates. One query reads every brand's.
class MarketingKitStatusTest < ActionDispatch::IntegrationTest
  URL = "https://drive.google.com/drive/folders/cw123"

  setup { log_in_as(users(:alex)) }

  def line(brand) = css_select("[data-test='marketing-kit-status'][data-brand='#{brand}']").first

  test "every brand shows its Google kit line: Up to date, Kit changed or No Google kit" do
    BrandKit.create!(brand: "welding_v2", saved_at: Time.utc(2026, 10, 20))
    BrandKit.create!(brand: "studio", saved_at: Time.utc(2026, 10, 22))
    BrandMarketingKit.create!(brand: "welding_v2", drive_url: URL, workspace: "commercialwelding.llc",
                              published_at: Time.utc(2026, 10, 21), published_saved_at: Time.utc(2026, 10, 20))
    BrandMarketingKit.create!(brand: "studio", drive_url: "#{URL}s", published_at: Time.utc(2026, 10, 21))
    get logos_path
    assert_response :success

    cw = line("welding_v2")
    assert_equal "📁 Google kit Up to date Open", cw.text.squish
    assert_equal "current", cw["data-status"]
    assert_includes cw.css("span")[1]["class"].split, "text-success-ink"
    assert_equal "Google kit in commercialwelding.llc: Kit saved Oct 20, 2026; published Oct 21, 2026 (kit of Oct 20, 2026)", cw["title"]
    open_link = cw.css("a[data-test='marketing-kit-link']").first
    assert_equal [URL, "_blank", "noopener"], [open_link["href"], open_link["target"], open_link["rel"]]

    studio = line("studio")
    assert_equal "📁 Google kit Kit changed Open", studio.text.squish
    assert_includes studio.css("span")[1]["class"].split, "text-warning-ink", "Kit changed is amber"

    none = line("turf")
    assert_equal "No Google kit", none.text.squish
    assert_equal "none", none["data-status"]
    assert_empty none.css("a"), "nothing to open"
    assert_equal Logos::NavbarLogo.brands.size, css_select("[data-test='marketing-kit-status']").size, "one line per brand"

    cell = css_select("[data-brand='welding_v2'] th").first
    assert_equal %w[logo-downloads logo-marketing-kit],
                 cell.css("[data-test='logo-downloads'], [data-test='logo-marketing-kit']").map { |n| n["data-test"] },
                 "the Google kit line sits under the downloads"
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
