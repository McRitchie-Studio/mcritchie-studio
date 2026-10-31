# frozen_string_literal: true

require "test_helper"

# [component] Which apps have the brand kit (tasks brand-kit-applied-status, logos-table-columns-tidy): the /logos
# brand cell has a chip per app a kit feeds (name, then a check, an amber triangle or a hollow ring for
# Applied / Kit changed / Not applied, the status in its accessible name, the dates in its title, opening the app's
# page), and the app's page shows a line per kit it takes.
class BrandKitAppStatusTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @kit = BrandKit.create!(brand: "studio", saved_at: Time.utc(2026, 10, 20, 15))
  end

  def chip(brand, app) = css_select("[data-test='kit-chip'][data-kind='app'][data-brand='#{brand}'][data-app='#{app}']").first
  def mark(node) = node.at_css("[data-test='kit-chip-mark']")["data-mark"]

  test "the /logos brand cell has a chip per linked app: its name, its status mark, its page" do
    BrandKitApp.create!(brand: "studio", app_slug: "mcritchie-studio", used_at: Time.utc(2026, 10, 21), applied_saved_at: Time.utc(2026, 10, 20, 15))
    BrandKitApp.create!(brand: "studio", app_slug: "turf-monster", used_at: Time.utc(2026, 10, 19), applied_saved_at: Time.utc(2026, 10, 1))
    BrandKitApp.create!(brand: "turf", app_slug: "turf-monster")
    log_in_as(@admin)
    get logos_path
    assert_response :success

    cell = css_select("[data-brand='studio'] th").first
    assert_equal %w[logo-downloads logo-kit-apps], cell.css("[data-test='logo-brand-subcolumns'] > div > [data-test='logo-downloads'], " \
                                                           "[data-test='logo-brand-subcolumns'] > [data-test='logo-kit-apps']").map { |n| n["data-test"] },
                 "under the brand's name, the downloads on the left and the chips on the right"
    assert_select "[data-test='logo-brands'] thead th", { text: "Apps and kits", count: 0 }, "no column of their own"
    assert_select "[data-test='logo-kit-status']", 0, "the 'Kit: saved … by' line is gone"

    hub = chip("studio", "mcritchie-studio")
    assert_equal "a", hub.name
    assert_equal application_path("mcritchie-studio"), hub["href"]
    assert_equal "McRitchie Studio", hub.at_css("[data-test='kit-chip-name']").text
    assert_equal "McRitchie Studio: Applied", hub["aria-label"]
    assert_equal "McRitchie Studio: Applied. Kit saved Oct 20, 2026; applied Oct 21, 2026 (kit of Oct 20, 2026)", hub["title"]
    assert_equal "done", mark(hub)

    turf = chip("studio", "turf-monster")
    assert_equal ["changed", "Turf Monster: Kit changed", "changed"], [turf["data-status"], turf["aria-label"], mark(turf)]
    assert_includes turf.at_css("[data-test='kit-chip-mark']")["class"].split, "text-warning-ink", "Kit changed is amber"

    fresh = chip("turf", "turf-monster")
    assert_equal ["Turf Monster: Not applied", "none"], [fresh["aria-label"], mark(fresh)]
    assert_equal "Turf Monster: Not applied. Kit never saved; not applied yet", fresh["title"]

    assert_select "[data-brand='industries'] [data-test='kit-chip'][data-kind='app']", 0, "a brand with no linked app has no app chip"
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
