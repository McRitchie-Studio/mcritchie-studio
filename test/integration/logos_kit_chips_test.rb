# frozen_string_literal: true

require "test_helper"

# [integration] The /logos brand cell (task logos-table-columns-tidy): every BrandKitApp link and every
# brand's Google kit is one chip in its own column, whose accessible name carries the status in words, whose mark on
# the right has its own shape per status, and which opens the app's page or the kit's Drive folder.
class LogosKitChipsTest < ActionDispatch::IntegrationTest
  URL = "https://drive.google.com/drive/folders/chips"

  setup do
    saved = Time.utc(2026, 10, 20)
    BrandKit.create!(brand: "studio", saved_at: saved)
    BrandKit.create!(brand: "industries", saved_at: saved)
    BrandKitApp.create!(brand: "studio", app_slug: "mcritchie-studio", used_at: saved + 1.day, applied_saved_at: saved)
    BrandKitApp.create!(brand: "studio", app_slug: "turf-monster", used_at: saved - 9.days, applied_saved_at: saved - 10.days)
    BrandKitApp.create!(brand: "industries", app_slug: "mcritchie-studio")
    BrandMarketingKit.create!(brand: "studio", drive_url: URL, owner: "team@mcritchie.studio", published_at: saved + 1.day, published_saved_at: saved)
    BrandMarketingKit.create!(brand: "industries", drive_url: "#{URL}2", owner: "team@mcritchie.industries", published_at: saved - 1.day)
    log_in_as(users(:alex))
  end

  def chips(brand) = css_select("[data-test='logo-brand-row'][data-brand='#{brand}'] [data-test='logo-kit-apps'] [data-test='kit-chip']")

  test "one chip per link and per Google kit, each with its status as accessible name and a mark per status" do
    get logos_path
    assert_response :success

    assert_equal [["app", "McRitchie Studio: Applied", "done", application_path("mcritchie-studio")],
                  ["app", "Turf Monster: Kit changed", "changed", application_path("turf-monster")],
                  ["google", "Google kit team@mcritchie.studio: Up to date", "done", URL]],
                 chips("studio").map { |c| [c["data-kind"], c["aria-label"], c.at_css("[data-test='kit-chip-mark']")["data-mark"], c["href"]] }
    assert_equal [["McRitchie Studio: Not applied", "none"], ["Google kit team@mcritchie.industries: Kit changed", "changed"]],
                 chips("industries").map { |c| [c["aria-label"], c.at_css("[data-test='kit-chip-mark']")["data-mark"]] }
    assert_equal [["No Google kit", "none", nil]],
                 chips("turf").map { |c| [c["aria-label"], c.at_css("[data-test='kit-chip-mark']")["data-mark"], c["href"]] }

    links = BrandKitApp.count
    assert_equal links + Logos::NavbarLogo.brands.size, css_select("[data-test='kit-chip']").size, "one chip per link, one Google chip per brand"
    css_select("[data-test='kit-chip']").each do |chip|
      assert_equal "true", chip.at_css("[data-test='kit-chip-mark']")["aria-hidden"], "the mark is decoration: the name says the status"
      assert chip["title"].start_with?(chip["aria-label"]), "the tooltip leads with the full name and status"
      assert_includes chip.at_css("[data-test='kit-chip-name']")["class"].split, "truncate", "a long name is cut, in full in the tooltip"
    end
    marks = css_select("[data-test='kit-chip-mark']").group_by { |m| m["data-mark"] }.transform_values { |ms| ms.map(&:inner_html).uniq }
    assert_equal %w[changed done none], marks.keys.sort
    assert marks.values.all? { |shapes| shapes.size == 1 }, "each status draws one shape"
    assert_equal 3, marks.values.flatten.uniq.size, "and no two statuses share a shape"
  end
end
