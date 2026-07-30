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

  # The scoping invariant DepthChartsController#authorize_reorder_entries relies on:
  # a chart's own has_many can never REACH another chart's entry by GLOBAL id, so
  # `chart.depth_chart_entries.where(id: posted_ids)` returns only the owned subset.
  # If this ever regressed to an unscoped lookup, the reorder IDOR reopens.
  test "a chart's entries association cannot reach a foreign entry by global id" do
    team_a  = Team.create!(name: "Own Squad", sport: "football", league: "nfl")
    chart_a = DepthChart.create!(team_slug: team_a.slug, slug: "#{team_a.slug}-depth")
    mine    = make_entry(chart_a, "QB", depth: 1)

    team_b  = Team.create!(name: "Foreign Squad", sport: "football", league: "nfl")
    chart_b = DepthChart.create!(team_slug: team_b.slug, slug: "#{team_b.slug}-depth")
    foreign = make_entry(chart_b, "QB", depth: 1)

    owned = chart_a.depth_chart_entries.where(id: [mine.id, foreign.id]).pluck(:id)
    assert_equal [mine.id], owned, "only the chart's OWN entry id resolves through its association"
    assert_empty chart_a.depth_chart_entries.where(id: foreign.id).to_a,
      "a foreign entry's global id is unreachable through another chart"
  end

  private

  def make_entry(chart, position, depth:)
    person = Person.create!(first_name: "Rank#{depth}", last_name: "Player#{SecureRandom.hex(3)}")
    DepthChartEntry.create!(depth_chart_slug: chart.slug, person_slug: person.slug,
                            position: position, side: "offense", depth: depth)
  end
end
