require "test_helper"

class ReleaseMembersHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "[component] release member summary highlights largest tasks and counts the rest" do
    measured_small = Task.create!(title: "Measured small work", stage: "reviewed", po_size: "small",
                                  metadata: { "devops" => { "repositories" => ["turf-monster"] } })
    measured_small.task_events.create!(to_stage: "reviewed", occurred_at: Time.current, cost: BigDecimal("12.5"))
    measured_medium = Task.create!(title: "Measured medium work", stage: "reviewed", dev_size: "medium",
                                   metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    measured_medium.task_events.create!(to_stage: "reviewed", occurred_at: Time.current, cost: BigDecimal("2.0"))
    forecast_large = Task.create!(title: "Large studio effort", stage: "reviewed", po_size: "large",
                                  metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    forecast_xl = Task.create!(title: "XL turf repair", stage: "reviewed", actual_size: "xl",
                               metadata: { "devops" => { "repositories" => ["turf-monster"] } })

    summary = release_member_condensed_summary([measured_medium, forecast_large, measured_small, forecast_xl])

    assert_equal [measured_small, measured_medium], summary[:highlights]
    assert_equal [
      { emoji: "🪎", count: 1, repositories: ["mcritchie-studio"] },
      { emoji: "🐊", count: 1, repositories: ["turf-monster"] }
    ], summary[:repo_counts]
  end

  test "[component] release member cost label prefers measured spend then size" do
    measured = Task.create!(title: "Measured studio work", stage: "reviewed", actual_size: "xl")
    measured.task_events.create!(to_stage: "reviewed", occurred_at: Time.current, cost: BigDecimal("12.5"))
    estimated = Task.create!(title: "Estimated studio work", stage: "reviewed", po_size: "large")
    unsized = Task.create!(title: "Unsized studio work", stage: "reviewed")

    assert_equal "$12.50", release_member_cost_label(measured)
    assert_equal "Measured task cost: $12.50", release_member_cost_title(measured)
    assert_equal "L", release_member_cost_label(estimated)
    assert_equal "Estimated task size: LARGE", release_member_cost_title(estimated)
    assert_nil release_member_cost_label(unsized)
    assert_equal "Task cost not measured", release_member_cost_title(unsized)
  end
end
