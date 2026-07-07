require "test_helper"
require "tempfile"

class NflCacheExpectedTeamTotalsTest < ActiveSupport::TestCase
  test "derives expected points from total and home spread" do
    expected = Nfl::CacheExpectedTeamTotals.derive(total: "44.5", home_spread: "-3.5")

    assert_equal BigDecimal("24.0"), expected[:home]
    assert_equal BigDecimal("20.5"), expected[:away]
  end

  test "caches home and away projections from source CSV" do
    NflTeamTotalProjection.where(game_slug: "buf-at-mia").delete_all
    csv = Tempfile.new(["team-totals", ".csv"])
    csv.write(<<~CSV)
      week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total,source
      1,buffalo-bills,miami-dolphins,buffalo-bills,-2.5,44.5,test_source
    CSV
    csv.close

    stats = Nfl::CacheExpectedTeamTotals.new(
      year: 2025,
      source_path: csv.path,
      source: "test_source",
      strict: true,
      verbose: false
    ).call

    assert_equal 1, stats[:games_cached]
    assert_equal 2, stats[:projections_upserted]

    home = NflTeamTotalProjection.find_by!(game_slug: "buf-at-mia", team_slug: "miami-dolphins")
    away = NflTeamTotalProjection.find_by!(game_slug: "buf-at-mia", team_slug: "buffalo-bills")

    assert_equal BigDecimal("21.0"), home.expected_points
    assert_equal BigDecimal("23.5"), away.expected_points
    assert_equal BigDecimal("2.5"), home.home_spread
    assert_equal BigDecimal("-2.5"), home.favorite_spread
    assert_equal "test_source", home.source
  ensure
    csv&.unlink
  end

  test "raises when strict source rows do not match a game" do
    csv = Tempfile.new(["team-totals-missing", ".csv"])
    csv.write(<<~CSV)
      week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total
      2,buffalo-bills,miami-dolphins,buffalo-bills,-2.5,44.5
    CSV
    csv.close

    error = assert_raises(RuntimeError) do
      Nfl::CacheExpectedTeamTotals.new(year: 2025, source_path: csv.path, strict: true, verbose: false).call
    end

    assert_match(/Missing games/, error.message)
  ensure
    csv&.unlink
  end
end
