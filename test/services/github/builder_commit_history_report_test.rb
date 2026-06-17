require "test_helper"

class Github::BuilderCommitHistoryReportTest < ActiveSupport::TestCase
  test "rolls weekly cache rows into totals calendar years and quarters" do
    builder = create_builder("ruby-builder")
    tracked = create_tracked_builder(builder)

    july_range = GithubCommitRange.for_week_start(Date.new(2021, 7, 24))
    october_range = GithubCommitRange.for_week_start(Date.new(2021, 10, 2))
    january_range = GithubCommitRange.for_week_start(Date.new(2022, 1, 1))
    create_cache(tracked, july_range, 2)
    create_cache(tracked, october_range, 3)
    create_cache(tracked, january_range, 5)

    report = Github::BuilderCommitHistoryReport.new(builders: [builder], end_date: Date.new(2022, 1, 1)).build
    row = report.rows.first

    assert_equal [2022, 2021], report.years
    assert_equal ["2022 Q1", "2021 Q4", "2021 Q3"], report.quarters.map(&:label)
    assert_equal 1, report.complete_rows_count
    assert_equal 0, report.incomplete_rows_count
    assert_equal 3, row[:cached_range_count]
    assert_equal 10, row[:total_commits_count]
    assert_equal 5, row[:year_totals][2022]
    assert_equal 5, row[:year_totals][2021]
    assert_equal 5, row[:quarter_totals][[2022, 1]]
    assert_equal 3, row[:quarter_totals][[2021, 4]]
    assert_equal 2, row[:quarter_totals][[2021, 3]]
    assert_equal 2, row[:weekly_counts][july_range.id]
  end

  private

  def create_builder(login)
    Builder.create!(
      person: Person.create!(first_name: login, last_name: "Person"),
      github_login: login,
      active: true,
      included_in_roster: true
    )
  end

  def create_tracked_builder(builder)
    TrackedGithubBuilder.create!(
      github_login: builder.github_login,
      display_name: builder.display_name,
      cohort: "control_builder",
      active: true
    )
  end

  def create_cache(tracked, range, commits_count)
    GithubBuilderCommitRangeCache.create!(
      tracked_github_builder: tracked,
      github_commit_range: range,
      github_login: tracked.github_login,
      cohort: tracked.cohort,
      commits_count: commits_count,
      non_merge_commits_count: commits_count,
      bot_adjusted_commits_count: commits_count,
      active_repos_count: 1,
      cached_at: Time.current
    )
  end
end
