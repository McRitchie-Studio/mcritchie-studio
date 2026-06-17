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
        cached_at: Time.current
      )
    end

    get builders_path

    assert_response :success
    assert_select "h2", "Builder Roster"
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
end
