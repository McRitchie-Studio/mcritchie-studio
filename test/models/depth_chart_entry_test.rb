require "test_helper"

# [unit] DepthChartEntry's board-primitive wiring (studio-engine 0.29.0 / DG1): it
# ranks by `depth` (1 = starter, on top) while `position` holds the lane-code string.
# The reorder/lock behavior itself is unit-tested in the engine (board_rankable_test);
# here we assert THIS model is configured to use those knobs, and that board_ordered
# reflects the depth-ascending sort.
class DepthChartEntryTest < ActiveSupport::TestCase
  test "is configured to rank by depth, ascending (position stays a lane string)" do
    assert_equal :depth,    DepthChartEntry.board_rank_attr, "ranks by depth, not position"
    assert_equal :asc,      DepthChartEntry.board_rank_order, "depth 1 (starter) sorts on top"
    assert_equal :position, DepthChartEntry.board_zone_attr, "the zone is the position lane"
  end

  test "board_ordered sorts a lane by depth ascending (starter first)" do
    team  = Team.create!(name: "Rank Test FC", sport: "football", league: "nfl")
    chart = DepthChart.create!(team_slug: team.slug, slug: "#{team.slug}-depth")
    third   = make_entry(chart, "QB", depth: 3)
    starter = make_entry(chart, "QB", depth: 1)
    backup  = make_entry(chart, "QB", depth: 2)

    ordered = DepthChartEntry.where(depth_chart_slug: chart.slug, position: "QB").board_ordered.to_a
    assert_equal [starter.id, backup.id, third.id], ordered.map(&:id),
      "depth 1 first, then 2, then 3 (ascending — the starter on top)"
  end

  private

  def make_entry(chart, position, depth:)
    person = Person.create!(first_name: "Rank#{depth}", last_name: "Player#{SecureRandom.hex(3)}")
    DepthChartEntry.create!(depth_chart_slug: chart.slug, person_slug: person.slug,
                            position: position, side: "offense", depth: depth)
  end
end
