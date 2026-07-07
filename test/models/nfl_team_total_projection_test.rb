require "test_helper"

class NflTeamTotalProjectionTest < ActiveSupport::TestCase
  test "belongs to season slate game team and opponent by slug" do
    projection = nfl_team_total_projections(:bills_at_dolphins_away)

    assert_equal seasons(:nfl_2025), projection.season
    assert_equal slates(:nfl_week1), projection.slate
    assert_equal games(:bills_at_dolphins), projection.game
    assert_equal teams(:buffalo_bills), projection.team
    assert_equal teams(:miami_dolphins), projection.opponent_team
  end

  test "validates team is a game participant" do
    projection = nfl_team_total_projections(:bills_at_dolphins_away).dup
    projection.team_slug = "argentina"

    assert_not projection.valid?
    assert_includes projection.errors[:team_slug], "must be one of the game's teams"
  end

  test "game exposes home and away expected totals" do
    game = games(:bills_at_dolphins)

    assert_equal BigDecimal("21.0"), game.home_expected_total
    assert_equal BigDecimal("23.5"), game.away_expected_total
  end
end
