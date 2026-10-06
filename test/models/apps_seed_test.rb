require "test_helper"

# Exercises db/seeds/00_apps.rb directly: it runs on every deploy, so it must be
# idempotent and must carry each managed app's status-line color (the source of
# truth bin/statusline tints the app slug with).
class AppsSeedTest < ActiveSupport::TestCase
  SEED = Rails.root.join("db/seeds/00_apps.rb").to_s

  def run_seed
    capture_io { load SEED }
  end

  test "seeds the managed-app registry and is idempotent" do
    run_seed
    first = App.count
    assert_operator first, :>=, 6, "expected the full managed-app registry"
    run_seed
    assert_equal first, App.count, "re-running the seed must not create duplicates"
  end

  test "[unit] the seed writes one row per catalog app and library, as the catalog says" do
    run_seed
    rows = AppCatalog.seed_rows
    assert_equal rows.map { |row| row[:slug] }.sort, App.pluck(:slug).sort
    rows.each do |row|
      app = App.find_by!(slug: row[:slug])
      assert_equal row.slice(:name, :color, :emoji, :status, :position),
                   { name: app.name, color: app.color, emoji: app.emoji, status: app.status, position: app.position },
                   "#{row[:slug]} drifted from config/apps.yml"
    end
  end

  test "[unit] a slug the name does not spell survives the save" do
    run_seed
    assert_equal "10&5 Hospitality", App.find_by!(slug: "10and5").name,
                 "Sluggable would rename 10and5 to 10-5-hospitality if the name drove the slug"
    assert_nil App.find_by(slug: "10-5-hospitality")
  end

  test "McRitchie Studio is lavender and Turf Monster is green" do
    run_seed
    assert_equal "#B57EDC", App.find_by!(slug: "mcritchie-studio").color
    assert_equal "#22C55E", App.find_by!(slug: "turf-monster").color
  end

  test "re-seeding writes nothing (no churn on every deploy)" do
    run_seed
    checkpoint = App.maximum(:updated_at)
    travel 2.seconds do
      run_seed
    end
    assert_equal checkpoint, App.maximum(:updated_at),
      "an unchanged re-seed must not bump any updated_at"
  end
end
