require "test_helper"

class Github::CommitFetcherTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:payloads, :calls) do
    def paginate(path, params:, headers: {})
      calls << { path: path, params: params, headers: headers }
      payloads
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
    fetcher = Github::CommitFetcher.new(client: client, logger: nil)

    2.times do
      fetcher.fetch_for_builder(builder: builder, start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 7))
    end

    assert_equal 1, GithubCommitObservation.where(github_login: "repo-builder", repo_full_name: "owner/repo", sha: "abc123").count
    assert client.calls.all? { |call| call[:path] == "/repos/owner/repo/commits" }
    assert_equal %i[author committer author committer], client.calls.map { |call| call[:params].keys.first }
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
end
