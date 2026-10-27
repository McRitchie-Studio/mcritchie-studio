# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261027180000_create_brand_kit_apps.rb").to_s

# [db] CreateBrandKitApps (task brand-kit-applied-status): reversible; backfills saved_at from updated_at for kits with
# a saved choice; seeds the five links, skipping an app with no row; stamps only the hub's link, and only when its
# committed kit.json is the studio kit; a second seed changes nothing.
class CreateBrandKitAppsMigrationTest < ActiveSupport::TestCase
  M = CreateBrandKitApps
  NAVBAR = { "rule" => 4, "text" => "second", "edits" => {}, "colouring" => "alt" }.freeze

  setup { @dir = Pathname(Dir.mktmpdir("brand-kit-apps-migration")) }
  teardown do
    FileUtils.rm_rf(@dir)
    [BrandKit, BrandKitApp].each(&:reset_column_information)
  end

  def quietly(&) = capture_io { ActiveRecord::Migration.suppress_messages(&) }
  def manifest(**choices) = @dir.join("kit.json").tap { |path| path.write(JSON.generate({ "brand" => "studio", "icon" => nil, "navbar" => nil, "stacked" => nil }.merge(choices.transform_keys(&:to_s)))) }
  def seed(path = manifest) = M.new.tap { |m| m.verbose = false }.seed_links(manifest_path: path)

  test "down then up: reversible, and the backfill stamps saved_at only on kits with a saved choice" do
    saved = BrandKit.create!(brand: "studio", navbar_choice: NAVBAR, updated_at: Time.utc(2026, 10, 14, 5, 25))
    bare = BrandKit.create!(brand: "turf", notes: "only a note")
    quietly { M.new.migrate(:down) }
    refute ActiveRecord::Base.connection.table_exists?(:brand_kit_apps)
    refute ActiveRecord::Base.connection.column_exists?(:brand_kits, :saved_at)

    quietly { M.new.migrate(:up) }
    BrandKit.reset_column_information
    assert_equal Time.utc(2026, 10, 14, 5, 25), saved.reload.saved_at
    assert_nil bare.reload.saved_at
    assert ActiveRecord::Base.connection.foreign_key_exists?(:brand_kit_apps, :apps, column: :app_slug)
  end

  test "the seeds file and the migration seed the same links" do
    assert_equal M::LINKS, BrandKitApp::SEED_LINKS
    out, = capture_io { 2.times { load Rails.root.join("db/seeds/05_brand_kit_apps.rb") } }
    assert_includes out, "skipped welding_v2 → commercial-welding (no app row)"
    assert_equal [%w[studio mcritchie-studio], %w[turf turf-monster]], BrandKitApp.order(:brand).pluck(:brand, :app_slug)
  end

  test "seeds a link per pair whose app exists, names the missing apps, and stamps nothing it cannot prove" do
    skipped = seed(manifest(navbar: NAVBAR))   # no studio kit row: nothing to prove the hub against
    assert_equal %w[mcritchie-industries commercial-welding], skipped
    assert_equal [%w[studio mcritchie-studio], %w[turf turf-monster]], BrandKitApp.order(:brand).pluck(:brand, :app_slug)
    assert BrandKitApp.all.all? { |link| link.used_at.nil? }
  end

  test "with every app present, welding and welding_v2 both feed commercial-welding" do
    App.create!(slug: "mcritchie-industries", name: "McRitchie Industries")
    App.create!(slug: "commercial-welding", name: "Commercial Welding")
    assert_empty seed
    assert_equal M::LINKS.sort, BrandKitApp.pluck(:brand, :app_slug).sort
    assert_equal %w[welding welding_v2], BrandKitApp.where(app_slug: "commercial-welding").order(:brand).pluck(:brand)
  end

  test "the hub's link is stamped with the kit's saved_at when its kit.json is the saved studio kit" do
    kit = BrandKit.create!(brand: "studio", navbar_choice: NAVBAR, saved_at: Time.utc(2026, 10, 20, 3))
    seed(manifest(navbar: NAVBAR))
    hub = BrandKitApp.find_by!(brand: "studio", app_slug: "mcritchie-studio")
    assert_equal [Time.utc(2026, 10, 20, 3)] * 2, [hub.used_at, hub.applied_saved_at]
    assert_equal M::STAMPED_BY, hub.used_by
    assert_equal :applied, hub.status(kit)
    assert_nil BrandKitApp.find_by!(brand: "turf").used_at, "turf-monster's install is not the hub's to prove"
  end

  test "a kit.json that differs from the studio kit leaves the hub Not applied" do
    BrandKit.create!(brand: "studio", navbar_choice: NAVBAR.merge("rule" => 3), saved_at: Time.utc(2026, 10, 20))
    seed(manifest(navbar: NAVBAR))
    assert_nil BrandKitApp.find_by!(brand: "studio").used_at
    seed(@dir.join("missing.json"))
    assert_nil BrandKitApp.find_by!(brand: "studio").used_at
  end

  test "a second seed changes nothing, and never overwrites a recorded application" do
    BrandKit.create!(brand: "studio", navbar_choice: NAVBAR, saved_at: Time.utc(2026, 10, 20))
    seed
    BrandKitApp.find_by!(brand: "turf").update!(used_at: Time.utc(2026, 10, 21), used_by: "steffon")
    before = BrandKitApp.order(:id).pluck(:brand, :app_slug, :used_at, :used_by, :applied_saved_at)
    seed(manifest(navbar: NAVBAR))
    seed(manifest(navbar: NAVBAR))
    after = BrandKitApp.order(:id).pluck(:brand, :app_slug, :used_at, :used_by, :applied_saved_at)
    assert_equal before.reject { |row| row[1] == "mcritchie-studio" }, after.reject { |row| row[1] == "mcritchie-studio" }
    assert_equal 1, BrandKitApp.where(brand: "studio").count
  end
end
