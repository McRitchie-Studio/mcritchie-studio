require "test_helper"

class Github::BuilderRosterCutoffTest < ActiveSupport::TestCase
  test "marks builders ranked below the cutoff as excluded from the roster" do
    high = create_builder("high-builder", "High Builder")
    cutoff = create_builder("mitchellh", "Mitchell Hashimoto")
    low = create_builder("low-builder", "Low Builder")
    week_start = Date.new(2026, 6, 13)

    create_cache(high, week_start, commits_count: 50)
    create_cache(cutoff, week_start, commits_count: 30)
    create_cache(low, week_start, commits_count: 10)

    result = Github::BuilderRosterCutoff.new(range_limit: 1).apply!(cutoff_login: "mitchellh")

    assert_equal 2, result[:cutoff_rank]
    assert_equal 2, result[:included_count]
    assert_equal 1, result[:excluded_count]
    assert Builder.find_by!(github_login: "high-builder").included_in_roster?
    assert Builder.find_by!(github_login: "mitchellh").included_in_roster?
    refute Builder.find_by!(github_login: "low-builder").included_in_roster?
  end

  test "raises when cutoff builder is not active" do
    create_builder("mitchellh", "Mitchell Hashimoto", active: false)

    assert_raises(ActiveRecord::RecordNotFound) do
      Github::BuilderRosterCutoff.new(range_limit: 1).apply!(cutoff_login: "mitchellh")
    end
  end

  private

  def create_builder(github_login, name, active: true)
    person = Person.create!(first_name: name, last_name: "Person")
    builder = Builder.create!(
      person: person,
      github_login: github_login,
      github_name: name,
      active: active,
      included_in_roster: true
    )
    TrackedGithubBuilder.create!(
      github_login: builder.github_login,
      display_name: name,
      cohort: "ai_builder",
      active: true
    )
    builder
  end

  def create_cache(builder, week_start, commits_count:)
    tracked_builder = TrackedGithubBuilder.find_by!(github_login: builder.github_login)
    GithubBuilderCommitRangeCache.create!(
      tracked_github_builder: tracked_builder,
      github_commit_range: GithubCommitRange.for_week_start(week_start),
      github_login: builder.github_login,
      cohort: tracked_builder.cohort,
      commits_count: commits_count,
      non_merge_commits_count: commits_count,
      bot_adjusted_commits_count: commits_count,
      active_repos_count: 1,
      cached_at: Time.current
    )
  end
end
