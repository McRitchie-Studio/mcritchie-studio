require "test_helper"

class BuildersControllerTest < ActionDispatch::IntegrationTest
  test "index renders builder roster with latest thirteen commit ranges and total" do
    person = Person.create!(
      first_name: "Yukihiro",
      last_name: "Matsumoto",
      location: "Matsue, Japan",
      avatar_url: "https://avatars.githubusercontent.com/u/1?v=4",
      website_url: "https://ruby-lang.org"
    )
    builder = Builder.create!(
      person: person,
      github_login: "matz",
      github_profile_url: "https://github.com/matz",
      primary_language: "Ruby",
      active: true
    )
    Builder.create!(
      person: Person.create!(first_name: "Java", last_name: "Script"),
      github_login: "not-ruby",
      primary_language: "JavaScript",
      active: true
    )
    tracked = TrackedGithubBuilder.create!(
      github_login: builder.github_login,
      display_name: builder.display_name,
      cohort: "control_builder",
      active: true
    )
    week_starts = (0..13).map { |index| Date.new(2026, 3, 28) + index.weeks }
    ranges = week_starts.map { |week_start| GithubCommitRange.for_week_start(week_start) }
    ranges.last(13).each_with_index do |range, index|
      GithubBuilderCommitRangeCache.create!(
        tracked_github_builder: tracked,
        github_commit_range: range,
        github_login: builder.github_login,
        cohort: tracked.cohort,
        commits_count: index + 1,
        non_merge_commits_count: index + 1,
        bot_adjusted_commits_count: index + 1,
        active_repos_count: 1,
        cache_run_key: Github::CommitCacheKey.current,
        cached_at: Time.current
      )
    end

    get builders_path

    assert_response :success
    assert_select "h2", "Builder Roster"
    assert_select "table"
    assert_select "a[href=?]", all_builders_path, "All Builders"
    assert_select "a[href=?]", "https://github.com/matz", "@matz"
    assert_select "td", "Matsue, Japan"
    assert_select "a[href=?]", "https://ruby-lang.org", "Website"
    assert_select "th", text: /Jun 26/
    assert_select "th", text: /Jun 19/
    assert_select "th", text: /Jun 12/
    assert_select "th", text: /Jun 5/
    assert_select "th", text: /Apr 3/, count: 0
    assert_select "th", text: /Total/
    assert_select "td", text: "91"
    assert_select "span[title=?]", "Normalized score from this builder's five-year cached weekly history", text: "8"
    assert_select "td span", text: "13"
    assert_select "td span", text: "1"
    assert_match "not-ruby", response.body
  end

  test "index can filter builders by primary language" do
    ruby_person = Person.create!(first_name: "Ruby", last_name: "Builder")
    js_person = Person.create!(first_name: "Java", last_name: "Script")
    Builder.create!(person: ruby_person, github_login: "ruby-builder", primary_language: "Ruby", active: true)
    Builder.create!(person: js_person, github_login: "js-builder", primary_language: "JavaScript", active: true)

    get builders_path(language: "Ruby")

    assert_response :success
    assert_select "h2", "Ruby Builder Roster"
    assert_match "ruby-builder", response.body
    assert_no_match "js-builder", response.body
  end

  test "index hides builders excluded from the roster without deleting them" do
    Builder.create!(
      person: Person.create!(first_name: "Included", last_name: "Builder"),
      github_login: "included-builder",
      active: true,
      included_in_roster: true
    )
    Builder.create!(
      person: Person.create!(first_name: "Excluded", last_name: "Builder"),
      github_login: "excluded-builder",
      active: true,
      included_in_roster: false
    )

    get builders_path

    assert_response :success
    assert_match "included-builder", response.body
    assert_no_match "excluded-builder", response.body
    assert Builder.exists?(github_login: "excluded-builder")
  end

  test "history renders included builders with totals years quarters and weekly counts" do
    included = Builder.create!(
      person: Person.create!(first_name: "Included", last_name: "History"),
      github_login: "included-history",
      active: true,
      included_in_roster: true
    )
    excluded = Builder.create!(
      person: Person.create!(first_name: "Excluded", last_name: "History"),
      github_login: "excluded-history",
      active: true,
      included_in_roster: false
    )
    included_tracked = TrackedGithubBuilder.create!(
      github_login: included.github_login,
      display_name: included.display_name,
      cohort: "control_builder",
      active: true
    )
    excluded_tracked = TrackedGithubBuilder.create!(
      github_login: excluded.github_login,
      display_name: excluded.display_name,
      cohort: "control_builder",
      active: true
    )
    old_range = GithubCommitRange.for_week_start(Date.new(2021, 7, 24))
    new_range = GithubCommitRange.for_week_start(Date.new(2022, 1, 1))
    create_cache(included_tracked, old_range, 4)
    create_cache(included_tracked, new_range, 8)
    create_cache(excluded_tracked, new_range, 99)

    get history_builders_path

    assert_response :success
    assert_select "h2", "Builder Commit History"
    assert_select "table"
    assert_select "a[href=?]", all_builders_path, "All Builders"
    assert_select "svg[aria-label=?]", "Quarterly commit counts by builder"
    assert_match "included-history", response.body
    assert_no_match "excluded-history", response.body
    assert_select "th", text: "Total"
    assert_select "th", text: /2022/
    assert_select "th", text: /Q1/
    assert_select "th", text: /Jul 30/
    assert_select "td", text: "12"
    assert_select "td", text: "8"
    assert_select "td", text: "4"
    assert_match "2/2 weeks", response.body
  end

  test "all renders focus and archived builders without roster actions for visitors" do
    focus = Builder.create!(
      person: Person.create!(first_name: "Focus", last_name: "Builder"),
      github_login: "focus-builder",
      primary_language: "Ruby",
      active: true,
      included_in_roster: true
    )
    archived = Builder.create!(
      person: Person.create!(first_name: "Archived", last_name: "Builder"),
      github_login: "archived-builder",
      primary_language: "Ruby",
      active: true,
      included_in_roster: false
    )
    tracked = TrackedGithubBuilder.create!(
      github_login: archived.github_login,
      display_name: archived.display_name,
      cohort: "control_builder",
      active: true
    )
    create_cache(tracked, GithubCommitRange.for_week_start(Date.new(2026, 1, 3)), 12)

    get all_builders_path(language: "Ruby")

    assert_response :success
    assert_select "h2", "All Ruby Builders"
    assert_match focus.github_login, response.body
    assert_match archived.github_login, response.body
    assert_select "form[action=?]", archive_builder_path(focus.github_login, redirect_to: "/builders/all?language=Ruby"), count: 0
    assert_select "form[action=?]", restore_builder_path(archived.github_login, redirect_to: "/builders/all?language=Ruby"), count: 0
    assert_select "td", text: "12"
  end

  test "all renders roster actions for admins" do
    log_in_as users(:alex)
    focus = Builder.create!(
      person: Person.create!(first_name: "Focus", last_name: "Builder"),
      github_login: "focus-builder",
      primary_language: "Ruby",
      active: true,
      included_in_roster: true
    )
    archived = Builder.create!(
      person: Person.create!(first_name: "Archived", last_name: "Builder"),
      github_login: "archived-builder",
      primary_language: "Ruby",
      active: true,
      included_in_roster: false
    )

    get all_builders_path(language: "Ruby")

    assert_response :success
    assert_select "form[action=?]", archive_builder_path(focus.github_login, redirect_to: "/builders/all?language=Ruby")
    assert_select "form[action=?]", restore_builder_path(archived.github_login, redirect_to: "/builders/all?language=Ruby")
  end

  test "archive removes a builder from focus views without deleting it" do
    log_in_as users(:alex)
    builder = Builder.create!(
      person: Person.create!(first_name: "Archive", last_name: "Target"),
      github_login: "archive-target",
      active: true,
      included_in_roster: true
    )

    patch archive_builder_path(builder.github_login), params: { redirect_to: history_builders_path }

    assert_redirected_to history_builders_path
    refute builder.reload.included_in_roster?
    assert Builder.exists?(builder.id)
  end

  test "archive requires admin" do
    log_in_as users(:viewer)
    builder = Builder.create!(
      person: Person.create!(first_name: "Archive", last_name: "Viewer"),
      github_login: "archive-viewer",
      active: true,
      included_in_roster: true
    )

    patch archive_builder_path(builder.github_login), params: { redirect_to: history_builders_path }

    assert_redirected_to root_path
    assert builder.reload.included_in_roster?
  end

  test "restore adds a builder back to focus views" do
    log_in_as users(:alex)
    builder = Builder.create!(
      person: Person.create!(first_name: "Restore", last_name: "Target"),
      github_login: "restore-target",
      active: true,
      included_in_roster: false
    )

    patch restore_builder_path(builder.github_login), params: { redirect_to: all_builders_path }

    assert_redirected_to all_builders_path
    assert builder.reload.included_in_roster?
  end

  private

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
      cache_run_key: Github::CommitCacheKey.current,
      cached_at: Time.current
    )
  end
end
