# frozen_string_literal: true

require "test_helper"
require "rake"

# [unit] Which apps take which brand kit (task brand-kit-applied-status): BrandKit#saved_at is the kit's version,
# stamped by a saved or cleared logo choice and by nothing else; a BrandKitApp link reads Applied, Kit changed or
# Not applied against it; `bin/rails logos:applied` records an application.
class BrandKitAppTest < ActiveSupport::TestCase
  BY = "alex@test.com"

  def params(**given) = ActionController::Parameters.new(given)
  def link(**attrs) = BrandKitApp.create!({ brand: "studio", app_slug: "mcritchie-studio" }.merge(attrs))

  test "saving or clearing a logo choice stamps saved_at; notes and originals do not" do
    kit = BrandKit.for("studio")
    travel_to(Time.utc(2026, 10, 27, 9)) { kit.save_choice(:navbar, params(rule: "4", text: "second"), by: BY) }
    assert_equal Time.utc(2026, 10, 27, 9), kit.reload.saved_at

    travel_to(Time.utc(2026, 10, 27, 10)) { kit.update!(notes: "a note", updated_by: BY) }
    assert_equal Time.utc(2026, 10, 27, 9), kit.reload.saved_at, "notes move updated_at only"
    assert_equal Time.utc(2026, 10, 27, 10), kit.updated_at

    travel_to(Time.utc(2026, 10, 27, 11)) { kit.save_choice(:icon, params(colouring: "alt"), by: BY) }
    assert_equal Time.utc(2026, 10, 27, 11), kit.reload.saved_at
    travel_to(Time.utc(2026, 10, 27, 12)) { kit.clear_choice(:icon, by: BY) }
    assert_equal Time.utc(2026, 10, 27, 12), kit.reload.saved_at, "clearing a choice changes what an app installs"
  end

  test "a refused choice stamps nothing" do
    kit = BrandKit.for("studio")
    assert_raises(BrandKit::Error) { kit.save_choice(:navbar, params(rule: "99", text: "second"), by: BY) }
    assert_nil kit.saved_at
  end

  test "status: Not applied until used, Applied while the kit is unchanged, Kit changed once it is saved again" do
    kit = BrandKit.for("studio")
    travel_to(Time.utc(2026, 10, 1)) { kit.save_choice(:navbar, params(rule: "4", text: "second"), by: BY) }
    row = link
    assert_equal :not_applied, row.status
    assert_equal "Not applied", row.status_label

    row.update!(used_at: Time.utc(2026, 10, 2), applied_saved_at: Time.utc(2026, 10, 1))
    assert_equal :applied, row.reload.status
    assert_equal "Applied", row.status_label

    travel_to(Time.utc(2026, 10, 3)) { kit.save_choice(:navbar, params(rule: "3", text: "second"), by: BY) }
    assert_equal :changed, row.reload.status
    assert_equal "Kit changed", row.status_label
  end

  test "the applied version decides, to the second, before the time it was applied" do
    kit = BrandKit.create!(brand: "studio", saved_at: Time.utc(2026, 10, 5, 12, 0, 0, 500_000))
    applied_old = link(used_at: Time.utc(2026, 10, 6), applied_saved_at: Time.utc(2026, 10, 4))
    assert_equal :changed, applied_old.status(kit), "applied after the save, but it carried the older kit"

    applied_old.update!(applied_saved_at: Time.utc(2026, 10, 5, 12))
    assert_equal :applied, applied_old.status(kit), "kit.json's saved_at is ISO 8601 seconds"
  end

  test "with no applied version recorded, used_at against saved_at decides; a kit never saved is Applied once used" do
    kit = BrandKit.create!(brand: "studio", saved_at: Time.utc(2026, 10, 5))
    assert_equal :applied, link(used_at: Time.utc(2026, 10, 5)).status(kit)
    BrandKitApp.delete_all
    assert_equal :changed, link(used_at: Time.utc(2026, 10, 4)).status(kit)
    BrandKitApp.delete_all
    assert_equal :applied, link(used_at: Time.utc(2026, 10, 4)).status(nil)
    kit.destroy!
    assert_equal :applied, BrandKitApp.last.status, "no kit row: nothing has been saved since"
  end

  test "a kit feeds many apps and an app takes many kits, one link per pair" do
    link
    link(app_slug: "turf-monster")
    link(brand: "welding")
    link(brand: "welding_v2")
    assert_equal %w[studio welding welding_v2], apps(:mcritchie_studio).brand_kit_apps.order(:brand).pluck(:brand)
    assert_equal %w[mcritchie-studio turf-monster], BrandKit.create!(brand: "studio").app_links.order(:app_slug).pluck(:app_slug)
    refute BrandKitApp.new(brand: "studio", app_slug: "mcritchie-studio").valid?
    refute BrandKitApp.new(brand: "nike", app_slug: "turf-monster").valid?
    assert_equal({ "studio" => %w[mcritchie-studio turf-monster] },
                 BrandKitApp.by_brand(%w[studio]).transform_values { |links| links.map(&:app_slug) })
  end

  test "record_applied! creates or updates the link with the kit's saved_at unless given" do
    BrandKit.create!(brand: "turf", saved_at: Time.utc(2026, 10, 7))
    row = travel_to(Time.utc(2026, 10, 8)) { BrandKitApp.record_applied!(brand: "turf", app_slug: "turf-monster", by: "alex") }
    assert_equal [Time.utc(2026, 10, 8), "alex", Time.utc(2026, 10, 7)], [row.used_at, row.used_by, row.applied_saved_at]

    again = BrandKitApp.record_applied!(brand: "turf", app_slug: "turf-monster", by: "steffon", at: Time.utc(2026, 10, 9),
                                        saved_at: Time.utc(2026, 10, 6))
    assert_equal row.id, again.id
    assert_equal :changed, again.status, "the app's live kit.json named an older version"
  end

  test "logos:applied records BRAND on APP, and refuses an unknown brand or app" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("logos:applied")
    task = Rake::Task["logos:applied"]
    BrandKit.create!(brand: "turf", saved_at: Time.utc(2026, 10, 7))
    out = with_env("BRAND" => "turf", "APP" => "turf-monster", "AT" => "2026-10-08T01:02:03Z", "BY" => "steffon",
                   "SAVED_AT" => "2026-10-07T00:00:00Z") { task.reenable; capture_io { task.invoke }.first }
    assert_match "turf → turf-monster: Applied (used 2026-10-08T01:02:03Z by steffon, kit saved 2026-10-07T00:00:00Z)", out
    row = BrandKitApp.find_by!(brand: "turf", app_slug: "turf-monster")
    assert_equal [Time.utc(2026, 10, 8, 1, 2, 3), "steffon"], [row.used_at, row.used_by]

    [{ "BRAND" => "nope", "APP" => "turf-monster" }, { "BRAND" => "turf", "APP" => "nope" },
     { "BRAND" => "turf", "APP" => "turf-monster", "AT" => "not a time" }].each do |env|
      error = assert_raises(SystemExit, env.inspect) { with_env(env) { task.reenable; capture_io { task.invoke } } }
      refute error.success?
    end
  end

  private

  def with_env(vars)
    keys = vars.keys | %w[AT BY SAVED_AT]
    saved = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV[key] = vars[key] }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
