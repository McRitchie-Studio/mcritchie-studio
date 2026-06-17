require "test_helper"

class Github::BuilderIndexCalculatorTest < ActiveSupport::TestCase
  test "calculates median for odd and even value counts" do
    assert_equal BigDecimal("2.0"), Github::BuilderIndexCalculator.median([1, 2, 3])
    assert_equal BigDecimal("2.5"), Github::BuilderIndexCalculator.median([1, 2, 3, 4])
  end

  test "calculates index week medians and difficulty-adjusted multiple" do
    week_start = Date.new(2026, 6, 6)
    [1, 2, 3, 4, 5].each_with_index do |multiple, index|
      create_metric("ai-#{index}", "ai_builder", week_start, multiple)
    end
    [2, 2, 2, 2, 2].each_with_index do |multiple, index|
      create_metric("control-#{index}", "control_builder", week_start, multiple)
    end

    Github::BuilderIndexCalculator.new(minimum_cohort_size: 5).calculate!(start_date: week_start, end_date: week_start)

    index_week = GithubBuilderIndexWeek.find_by!(week_start_date: week_start)
    assert_equal 3, index_week.ai_builder_multiple
    assert_equal 2, index_week.control_builder_multiple
    assert_equal 1.5, index_week.difficulty_adjusted_ai_builder_multiple
    assert_nil index_week.notes
  end

  test "stores incomplete notes when cohort sizes are below minimum" do
    week_start = Date.new(2026, 6, 6)
    create_metric("ai-1", "ai_builder", week_start, 2)
    create_metric("control-1", "control_builder", week_start, 2)

    Github::BuilderIndexCalculator.new(minimum_cohort_size: 5).calculate!(start_date: week_start, end_date: week_start)

    index_week = GithubBuilderIndexWeek.find_by!(week_start_date: week_start)
    assert_nil index_week.ai_builder_multiple
    assert_nil index_week.difficulty_adjusted_ai_builder_multiple
    assert_includes index_week.notes, "ai_builder_count 1 below minimum 5"
    assert_includes index_week.notes, "control_builder_count 1 below minimum 5"
  end

  private

  def create_metric(login, cohort, week_start, multiple)
    GithubBuilderWeeklyMetric.create!(
      github_login: login,
      cohort: cohort,
      week_start_date: week_start,
      commits_count: 10,
      non_merge_commits_count: 10,
      bot_adjusted_commits_count: 10,
      active_repos_count: 1,
      trailing_90d_avg_weekly_commits: 5,
      builder_multiple: multiple,
      bot_adjusted_builder_multiple: multiple
    )
  end
end
