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
