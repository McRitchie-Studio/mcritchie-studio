require "test_helper"
require "rake"
require "tempfile"

class NflExpectedTeamTotalsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("nfl:expected_team_totals_cache")
    Rake::Task["nfl:expected_team_totals_cache"].reenable
  end

  test "nfl expected team totals task populates projections from CSV" do
    NflTeamTotalProjection.where(game_slug: "buf-at-mia").delete_all
    csv = Tempfile.new(["rake-team-totals", ".csv"])
    csv.write(<<~CSV)
      week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total,source
      1,buffalo-bills,miami-dolphins,buffalo-bills,-2.5,44.5,rake_test
    CSV
    csv.close

    ENV["YEAR"] = "2025"
    ENV["SOURCE"] = csv.path
    ENV["SOURCE_NAME"] = "rake_test"
    ENV["SEED_SCHEDULE"] = "0"

    out, = capture_io { Rake::Task["nfl:expected_team_totals_cache"].invoke }

    assert_match(/Expected team totals cached for 2025-nfl/, out)
    assert_equal 2, NflTeamTotalProjection.where(game_slug: "buf-at-mia", source: "rake_test").count
  ensure
    ENV.delete("YEAR")
    ENV.delete("SOURCE")
    ENV.delete("SOURCE_NAME")
    ENV.delete("SEED_SCHEDULE")
    csv&.unlink
  end
end
