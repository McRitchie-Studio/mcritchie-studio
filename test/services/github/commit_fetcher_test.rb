require "test_helper"

class Github::CommitFetcherTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:payloads, :calls) do
    def paginate(path, params:, headers: {})
      calls << { path: path, params: params, headers: headers }
      payloads.is_a?(Hash) ? Array(payloads.fetch(path, [])) : payloads
    end
  end

  test "uses repo-scoped strategy when builder has tracked repos and upserts idempotently" do
    builder = TrackedGithubBuilder.create!(github_login: "repo-builder", cohort: "ai_builder")
    builder.tracked_github_builder_repos.create!(repo_full_name: "owner/repo")
    payload = {
      "sha" => "abc123",
      "html_url" => "https://github.com/owner/repo/commit/abc123",
      "author" => { "login" => "repo-builder" },
      "committer" => { "login" => "repo-builder" },
      "parents" => [{ "sha" => "parent" }],
      "commit" => {
        "author" => { "name" => "Repo Builder", "date" => "2026-06-01T12:00:00Z" },
        "committer" => { "name" => "Repo Builder", "date" => "2026-06-01T12:00:00Z" },
        "message" => "Ship public build velocity module"
      }
    }
    client = FakeClient.new([payload], [])
    fetcher = Github::CommitFetcher.new(client: client, logger: nil, repo_scope_min_observations: 0)

    2.times do
      fetcher.fetch_for_builder(builder: builder, start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 7))
    end

    assert_equal 1, GithubCommitObservation.where(github_login: "repo-builder", repo_full_name: "owner/repo", sha: "abc123").count
    assert client.calls.all? { |call| call[:path] == "/repos/owner/repo/commits" }
    assert_equal %i[author committer author committer], client.calls.map { |call| call[:params].keys.first }
  end

  test "supplements sparse repo-scoped results with commit search" do
    builder = TrackedGithubBuilder.create!(github_login: "sparse-builder", cohort: "ai_builder")
    builder.tracked_github_builder_repos.create!(repo_full_name: "owner/repo")
    repo_payload = {
      "sha" => "repo123",
      "html_url" => "https://github.com/owner/repo/commit/repo123",
      "author" => { "login" => "sparse-builder" },
      "commit" => {
        "author" => { "date" => "2026-06-01T12:00:00Z" },
        "committer" => { "date" => "2026-06-01T12:00:00Z" },
        "message" => "Repo scoped commit"
      }
    }
    search_payload = {
      "sha" => "search123",
      "html_url" => "https://github.com/other/repo/commit/search123",
      "repository" => { "full_name" => "other/repo" },
      "author" => { "login" => "sparse-builder" },
      "commit" => {
        "author" => { "date" => "2026-06-02T12:00:00Z" },
        "committer" => { "date" => "2026-06-02T12:00:00Z" },
        "message" => "Search supplement commit"
      }
    }
    client = FakeClient.new(
      {
        "/repos/owner/repo/commits" => [repo_payload],
        "/search/commits" => [search_payload]
      },
      []
    )

    result = Github::CommitFetcher.new(
      client: client,
      logger: nil,
      repo_scope_min_observations: 2
    ).fetch_for_builder(
      builder: builder,
      start_date: Date.new(2026, 6, 1),
      end_date: Date.new(2026, 6, 7)
    )

    assert_equal "repo_scoped_with_search_supplement", result[:strategy]
    assert_equal 1, GithubCommitObservation.where(github_login: "sparse-builder", source_strategy: "repo_scoped").count
    assert_equal 1, GithubCommitObservation.where(github_login: "sparse-builder", source_strategy: "search").count
    assert client.calls.any? { |call| call[:path] == "/repos/owner/repo/commits" }
    assert client.calls.any? { |call| call[:path] == "/search/commits" }
  end

  test "falls back to search strategy when no repos are attached" do
    builder = TrackedGithubBuilder.create!(github_login: "search-builder", cohort: "ai_builder")
    payload = {
      "sha" => "search123",
      "html_url" => "https://github.com/owner/repo/commit/search123",
      "repository" => { "full_name" => "owner/repo" },
      "author" => { "login" => "search-builder" },
      "commit" => {
        "author" => { "name" => "Search Builder", "date" => "2026-06-01T12:00:00Z" },
        "committer" => { "name" => "Search Builder", "date" => "2026-06-01T12:00:00Z" },
        "message" => "Search sourced commit"
      }
    }
    client = FakeClient.new([payload], [])

    Github::CommitFetcher.new(client: client, logger: nil).fetch_for_builder(
      builder: builder,
      start_date: Date.new(2026, 6, 1),
      end_date: Date.new(2026, 6, 7)
    )

    assert_equal 1, GithubCommitObservation.where(github_login: "search-builder", source_strategy: "search").count
    assert client.calls.all? { |call| call[:path] == "/search/commits" }
    assert_includes client.calls.first[:params][:q], "author:search-builder"
    assert_includes client.calls.first[:params][:q], "author-date:2026-06-01..2026-06-07"
  end

  test "calls segment callback after each search date range" do
    builder = TrackedGithubBuilder.create!(github_login: "segment-builder", cohort: "ai_builder")
    payload = {
      "sha" => "segment123",
      "html_url" => "https://github.com/owner/repo/commit/segment123",
      "repository" => { "full_name" => "owner/repo" },
      "author" => { "login" => "segment-builder" },
      "commit" => {
        "author" => { "name" => "Segment Builder", "date" => "2026-06-01T12:00:00Z" },
        "committer" => { "name" => "Segment Builder", "date" => "2026-06-01T12:00:00Z" },
        "message" => "Segment callback commit"
      }
    }
    client = FakeClient.new([payload], [])
    segments = []

    Github::CommitFetcher.new(client: client, logger: nil, search_range_days: 7).fetch_for_builder(
      builder: builder,
      start_date: Date.new(2026, 6, 1),
      end_date: Date.new(2026, 6, 14),
      after_segment: ->(range_start, range_end) { segments << [range_start, range_end] }
    )

    assert_equal [
      [Date.new(2026, 6, 1), Date.new(2026, 6, 7)],
      [Date.new(2026, 6, 8), Date.new(2026, 6, 14)]
    ], segments
  end
end
