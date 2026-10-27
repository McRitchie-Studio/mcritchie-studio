# frozen_string_literal: true

require "test_helper"

# [component] Which apps have the brand kit (task brand-kit-applied-status): the /logos brand column lists each app a
# kit feeds under its downloads (emoji, name, Applied / Kit changed / Not applied; Kit changed in the amber tone with the
# kit's save date in its title), and the app's page shows the same line per kit it takes.
class BrandKitAppStatusTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @kit = BrandKit.create!(brand: "studio", saved_at: Time.utc(2026, 10, 20, 15))
  end

  def line(brand, app) = css_select("[data-test='kit-app-status'][data-brand='#{brand}'][data-app='#{app}']").first
  def status_word(node) = node.css("span").last

  test "the /logos brand column lists each linked app with its status, under the downloads" do
    BrandKitApp.create!(brand: "studio", app_slug: "mcritchie-studio", used_at: Time.utc(2026, 10, 21), applied_saved_at: Time.utc(2026, 10, 20, 15))
    BrandKitApp.create!(brand: "studio", app_slug: "turf-monster", used_at: Time.utc(2026, 10, 19), applied_saved_at: Time.utc(2026, 10, 1))
    BrandKitApp.create!(brand: "turf", app_slug: "turf-monster")
    log_in_as(@admin)
    get logos_path
    assert_response :success

    cell = css_select("[data-brand='studio'] th").first
    assert_equal %w[logo-downloads logo-kit-apps], cell.css("[data-test='logo-downloads'], [data-test='logo-kit-apps']").map { |n| n["data-test"] },
                 "the app lines sit under the download links"
    assert_select "[data-test='logo-kit-status']", 0, "the 'Kit: saved … by' line is gone"

    hub = line("studio", "mcritchie-studio")
    assert_equal "🪎 McRitchie Studio Applied", hub.text.squish
    assert_includes status_word(hub)["class"].split, "text-success-ink"
    assert_equal "🪎 McRitchie Studio: Kit saved Oct 20, 2026; applied Oct 21, 2026 (kit of Oct 20, 2026)", hub["title"]

    turf = line("studio", "turf-monster")
    assert_equal "🐊 Turf Monster Kit changed", turf.text.squish
    assert_equal "changed", turf["data-status"]
    assert_includes status_word(turf)["class"].split, "text-warning-ink", "Kit changed is amber"
    assert_match(/\A🐊 Turf Monster: Kit saved Oct 20, 2026; /, turf["title"], "the title gives the kit's save date")

    fresh = line("turf", "turf-monster")
    assert_equal "🐊 Turf Monster Not applied", fresh.text.squish
    assert_equal "🐊 Turf Monster: Kit never saved; not applied yet", fresh["title"]
    assert_includes status_word(fresh)["class"].split, "text-muted"

    assert_select "[data-brand='industries'] [data-test='logo-kit-apps']", 0, "a brand with no linked app shows no list"
  end

  test "the table reads every app link in one query, whatever the number of brands and apps" do
    %w[studio turf welding].each { |brand| BrandKitApp.create!(brand:, app_slug: "turf-monster") }
    BrandKitApp.create!(brand: "studio", app_slug: "mcritchie-studio")
    log_in_as(@admin)
    get logos_path
    counted = []
    counter = ->(*, payload) { counted << payload[:sql] if payload[:sql].include?("brand_kit_apps") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get logos_path }
    assert_equal 1, counted.size, counted.join("\n")
  end

  test "the app's page shows each kit it takes with its status, the brand linked to /logos for an admin" do
    BrandKitApp.create!(brand: "studio", app_slug: "turf-monster", used_at: Time.utc(2026, 10, 19))
    BrandKitApp.create!(brand: "turf", app_slug: "turf-monster", used_at: Time.utc(2026, 10, 25))
    log_in_as(@admin)
    get application_path("turf-monster")
    assert_response :success

    card = css_select("[data-test='application-brand-kits']").first
    assert card, "the Brand kit card renders"
    assert_equal ["McRitchie Studio Kit changed", "Turf Monster Applied"], card.css("[data-test='kit-app-status']").map { |n| n.text.squish }
    assert_select "[data-test='application-brand-kits'] a[href=?]", logo_brand_path("studio"), text: "McRitchie Studio"
  end

  test "an owner sees the status without the admin-only /logos link; an app with no kit has no card" do
    Agent.create!(slug: "turf-monster", name: "Turf Monster", status: "active", agent_type: "specialist")
    owner = User.create!(email: "owner@turfmonster.media", name: "Turf Owner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: owner)
    BrandKitApp.create!(brand: "turf", app_slug: "turf-monster")
    log_in_as(owner)
    get application_path("turf-monster")
    assert_response :success
    assert_select "[data-test='application-brand-kits'] [data-test='kit-app-status']", text: /Turf Monster\s+Not applied/
    assert_select "[data-test='application-brand-kits'] a", 0

    log_in_as(@admin)
    get application_path("mcritchie-studio")
    assert_response :success
    assert_select "[data-test='application-brand-kits']", 0
  end
end
