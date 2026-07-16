require "test_helper"

# [unit] Ci::ProgressReader — resolves a SHA and reads GitHub check-runs into a
# Ci::CheckProgress, cached and degrading to blank. The Github::Client is injected
# (its executor seam) so nothing here touches the network.
class Ci::ProgressReaderTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](key)
      headers[key] || headers[key.to_s.downcase]
    end
  end

  setup { GithubWorkflowRun.delete_all }

  test "[unit] for_sha folds the check-runs payload into a CheckProgress" do
    reader = build_reader(&ok([
      { "status" => "completed", "conclusion" => "success" },
      { "status" => "in_progress" }
    ]))

    progress = reader.for_sha("amcritchie/mcritchie-studio", "sha1")
    assert_equal 1, progress.passed
    assert_equal 1, progress.pending
    assert_equal :pending, progress.state
  end

  test "[unit] for_sha caches so a second read makes no API call" do
    calls = 0
    reader = build_reader do |_uri, _req|
      calls += 1
      FakeResponse.new("200", check_runs_body([{ "status" => "completed", "conclusion" => "success" }]),
                       { "x-ratelimit-remaining" => "50" })
    end

    2.times { reader.for_sha("nwo/x", "sha") }
    assert_equal 1, calls, "second read must be served from cache"
  end

  test "[unit] a failing API degrades to blank, never raises" do
    reader = build_reader { |_uri, _req| FakeResponse.new("404", '{"message":"Not Found"}', {}) }

    assert_nothing_raised do
      progress = reader.for_sha("nwo/x", "missing")
      assert_not progress.present?
    end
  end

  test "[unit] a fixture short-circuits the network for a demo/test SHA" do
    calls = 0
    reader = build_reader(fixtures: { "demo-sha" => { "passed" => 5, "failed" => 0, "pending" => 3 } }) do |_uri, _req|
      calls += 1
      FakeResponse.new("500", "boom", {})
    end

    progress = reader.for_sha("nwo/x", "demo-sha")
    assert_equal 0, calls, "a fixture SHA never calls GitHub"
    assert_equal "5 / 8", progress.fraction_label
  end

  test "[unit] for_task is blank until submitted with a PR and a CI run" do
    reader = build_reader(fixtures: { "task-sha" => { "passed" => 2, "failed" => 0, "pending" => 6 } }, &ok([]))

    building = make_task(stage: "building", pr_url: nil, branch: "feat/ci-bars")
    assert_not reader.for_task(building).present?, "a building task shows no bar"

    submitted = make_task(stage: "submitted", pr_url: pr_url, branch: "feat/ci-bars")
    assert_not reader.for_task(submitted).present?, "no CI run row yet degrades to blank"

    seed_run(branch: "feat/ci-bars", sha: "task-sha")
    assert_equal "2 / 8", reader.for_task(submitted).fraction_label
  end

  test "[unit] progress_by_slug batches eligible tasks and skips the rest" do
    reader = build_reader(fixtures: {
      "sha-a" => { "passed" => 4, "failed" => 0, "pending" => 4 },
      "sha-b" => { "passed" => 8, "failed" => 0, "pending" => 0 }
    }, &ok([]))

    a = make_task(stage: "submitted", pr_url: pr_url, branch: "feat/a")
    b = make_task(stage: "reviewed", pr_url: pr_url, branch: "feat/b")
    building = make_task(stage: "building", pr_url: nil, branch: "feat/c")
    seed_run(branch: "feat/a", sha: "sha-a")
    seed_run(branch: "feat/b", sha: "sha-b")

    map = reader.progress_by_slug([a, b, building])
    assert_equal "4 / 8", map[a.slug].fraction_label
    assert_equal "8 / 8", map[b.slug].fraction_label
    assert_nil map[building.slug], "an ineligible task is absent from the map"
  end

  test "[unit] for_release shows the release-branch tip only while active" do
    reader = build_reader(fixtures: { "release-sha" => { "passed" => 8, "failed" => 0, "pending" => 0 } }, &ok([]))
    seed_run(branch: Release::BRANCH, sha: "release-sha")

    assert_equal "8 / 8", reader.for_release(Release.new(state: "assembling")).fraction_label
    assert_not reader.for_release(Release.new(state: "shipped")).present?
  end

  private

  def pr_url
    "https://github.com/amcritchie/mcritchie-studio/pull/9"
  end

  def build_reader(fixtures: nil, &executor)
    client = Github::Client.new(token: "t", logger: nil, sleeper: ->(_s) { }, max_retries: 0, executor: executor)
    Ci::ProgressReader.new(client: client, cache: ActiveSupport::Cache::MemoryStore.new, fixtures: fixtures)
  end

  def check_runs_body(runs)
    { "total_count" => runs.size, "check_runs" => runs }.to_json
  end

  def ok(runs)
    ->(_uri, _req) { FakeResponse.new("200", check_runs_body(runs), { "x-ratelimit-remaining" => "50" }) }
  end

  def make_task(stage:, pr_url:, branch:)
    devops = { "branch" => branch, "repositories" => ["mcritchie-studio"] }
    devops["pr_url"] = pr_url if pr_url
    Task.create!(title: "ci bar task #{SecureRandom.hex(3)}", stage: stage, metadata: { "devops" => devops })
  end

  def seed_run(branch:, sha:)
    GithubWorkflowRun.create!(
      repo: "amcritchie/mcritchie-studio", workflow_name: "CI",
      run_id: SecureRandom.random_number(10**12), status: "in_progress",
      head_branch: branch, head_sha: sha, run_started_at: Time.current
    )
  end
end
