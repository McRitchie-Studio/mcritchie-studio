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

  setup do
    GithubWorkflowRun.delete_all
    CiCheckJob.delete_all
  end

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

  test "[unit] for_release returns one CheckProgress per member repo" do
    reader = build_reader(fixtures: {
      "hub-rc"  => { "passed" => 8, "failed" => 0, "pending" => 0 },
      "turf-rc" => { "passed" => 3, "failed" => 0, "pending" => 5 }
    }, &ok([]))
    rel = release_with_members("mcritchie-studio", "turf-monster")
    seed_run(repo: "amcritchie/mcritchie-studio", branch: Release::BRANCH, sha: "hub-rc")
    seed_run(repo: "amcritchie/turf-monster",     branch: Release::BRANCH, sha: "turf-rc")

    progress = reader.for_release(rel)
    assert_equal %w[mcritchie-studio turf-monster], progress.keys.sort
    assert_equal "8 / 8", progress["mcritchie-studio"].fraction_label
    assert_equal "3 / 8", progress["turf-monster"].fraction_label
  end

  test "[unit] for_release is empty unless the release is active" do
    # The active? gate short-circuits BEFORE member enumeration, so an unpersisted
    # stub is enough — an inactive release shows no tracks at all.
    assert_empty Ci::ProgressReader.new.for_release(Release.new(state: "shipped"))
  end

  test "[unit] for_release resolves a gem member from its main suite CI, not the consumer CI" do
    reader = build_reader(fixtures: { "engine-rc" => { "passed" => 6, "failed" => 0, "pending" => 0 } }, &ok([]))
    rel = release_with_members("studio-engine")
    # The gem's OWN suite (Engine CI on main) IS the RC verdict...
    seed_run(repo: "amcritchie/studio-engine", branch: "main", sha: "engine-rc", workflow: "Engine CI")
    # ...NOT the downstream Consumer CI that also runs on main — and it is NEWER, so a
    # missing workflow-name filter would wrongly pick it.
    seed_run(repo: "amcritchie/studio-engine", branch: "main", sha: "consumer-rc",
             workflow: "Consumer CI", started_at: 1.minute.from_now)

    progress = reader.for_release(rel)
    assert_equal ["studio-engine"], progress.keys
    assert_equal "6 / 6", progress["studio-engine"].fraction_label,
                 "the gem track must read Engine CI, not the Consumer CI on the same branch"
  end

  test "[unit] a gem track folds ONLY its own workflow, not a failing sibling on the same SHA" do
    # THE REVIEWERS' LIVE CASE: studio-engine main carries Engine CI = success AND
    # Consumer CI = failure on the SAME SHA, and the commit check-runs endpoint returns
    # BOTH. The gem track must reflect Engine CI ONLY — a failing Consumer CI must not
    # drag it red — and must read that from the workflow-scoped LIVE rows, never the
    # workflow-blind API.
    calls = 0
    reader = build_reader do |_uri, _req|
      calls += 1
      FakeResponse.new("500", "the blind check-runs API must NOT be consulted for a gem", {})
    end
    rel = release_with_members("studio-engine")
    seed_run(repo: "amcritchie/studio-engine", branch: "main", sha: "engine-mix-sha", workflow: "Engine CI")
    seed_check_job(repo: "amcritchie/studio-engine", sha: "engine-mix-sha", workflow: "Engine CI", conclusion: "success")
    seed_check_job(repo: "amcritchie/studio-engine", sha: "engine-mix-sha", workflow: "Engine CI", conclusion: "success")
    seed_check_job(repo: "amcritchie/studio-engine", sha: "engine-mix-sha", workflow: "Consumer CI", conclusion: "failure")

    progress = reader.for_release(rel)["studio-engine"]
    assert_equal :green, progress.state,
                 "a failing Consumer CI on the same SHA must NOT drag the Engine CI track red"
    assert_equal "2 / 2", progress.fraction_label, "only the 2 Engine CI checks are folded"
    assert_equal 0, calls, "the gem fold reads live per-workflow rows only; the blind API is never consulted"
  end

  test "[unit] a member repo with no ingested run yields a blank (invisible) track" do
    reader = build_reader(&ok([]))
    rel = release_with_members("turf-monster")

    progress = reader.for_release(rel)
    assert progress.key?("turf-monster"), "the slot must exist so the live morph target pre-renders"
    assert_not progress["turf-monster"].present?, "with no run it degrades to a blank bar"
  end

  test "[unit] release_ci_slot_for morphs only a member repo on its own release-CI branch" do
    reader = build_reader(fixtures: { "turf-rc" => { "passed" => 2, "failed" => 0, "pending" => 6 } }, &ok([]))
    rel = release_with_members("turf-monster")
    seed_run(repo: "amcritchie/turf-monster", branch: Release::BRANCH, sha: "turf-rc")

    repo, progress = reader.release_ci_slot_for(rel, "amcritchie/turf-monster", Release::BRANCH)
    assert_equal "turf-monster", repo
    assert_equal "2 / 8", progress.fraction_label

    assert_nil reader.release_ci_slot_for(rel, "amcritchie/turf-monster", "main"),
               "an app repo push on the WRONG branch does not fire its release track"
    assert_nil reader.release_ci_slot_for(rel, "amcritchie/rolio", Release::BRANCH),
               "a NON-member repo never fires a release track"
  end

  # ── live-first: the workflow_job (CiCheckJob) path preferred over the API ──

  test "[unit] for_sha folds ingested CiCheckJob rows and never calls the API" do
    calls = 0
    reader = build_reader do |_uri, _req|
      calls += 1
      FakeResponse.new("500", "boom — the API must not be reached", {})
    end
    seed_jobs("nwo/x", "live-sha", passed: 5, pending: 3)

    progress = reader.for_sha("nwo/x", "live-sha")
    assert_equal "5 / 8", progress.fraction_label
    assert_equal :pending, progress.state
    assert_equal 0, calls, "live rows must short-circuit the GitHub API entirely"
  end

  test "[unit] for_sha falls back to the API when no check jobs are ingested" do
    reader = build_reader(&ok([{ "status" => "completed", "conclusion" => "success" }]))

    progress = reader.for_sha("nwo/x", "no-jobs-sha")
    assert_equal "1 / 1", progress.fraction_label, "with no live rows the API read is used"
  end

  test "[unit] for_task prefers live check-job rows over the API fallback" do
    reader = build_reader { |_uri, _req| FakeResponse.new("500", "API must not be hit", {}) }
    task = make_task(stage: "submitted", pr_url: pr_url, branch: "feat/live")
    seed_run(branch: "feat/live", sha: "task-live-sha")
    seed_jobs("amcritchie/mcritchie-studio", "task-live-sha", passed: 7, pending: 1)

    assert_equal "7 / 8", reader.for_task(task).fraction_label
  end

  test "[unit] eligible_tasks_for returns the submitted-onward tasks on the repo+branch" do
    submitted = make_task(stage: "submitted", pr_url: pr_url, branch: "feat/match")
    reviewed = make_task(stage: "reviewed", pr_url: pr_url, branch: "feat/match")
    make_task(stage: "building", pr_url: nil, branch: "feat/match")   # no PR → ineligible
    make_task(stage: "submitted", pr_url: pr_url, branch: "feat/other") # wrong branch

    slugs = Ci::ProgressReader.new.eligible_tasks_for("amcritchie/mcritchie-studio", "feat/match").map(&:slug)
    assert_equal [submitted.slug, reviewed.slug].sort, slugs.sort
  end

  test "[unit] eligible_tasks_for is empty for a blank repo or branch" do
    reader = Ci::ProgressReader.new
    assert_empty reader.eligible_tasks_for("", "feat/x")
    assert_empty reader.eligible_tasks_for("nwo/x", "")
  end

  test "[unit] the fixture seam is disabled in production" do
    ENV["CI_PROGRESS_FIXTURES"] = { "demo" => { "passed" => 1, "failed" => 0, "pending" => 0 } }.to_json
    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      assert_empty Ci::ProgressReader.new.send(:env_fixtures),
        "CI_PROGRESS_FIXTURES must never paint fake bars on a production dyno"
    end
  ensure
    ENV.delete("CI_PROGRESS_FIXTURES")
  end

  private

  def seed_jobs(repo, sha, passed: 0, failed: 0, pending: 0)
    id = SecureRandom.random_number(10**12)
    passed.times  { CiCheckJob.create!(repo: repo, job_id: (id += 1), head_sha: sha, workflow_name: "CI", status: "completed", conclusion: "success") }
    failed.times  { CiCheckJob.create!(repo: repo, job_id: (id += 1), head_sha: sha, workflow_name: "CI", status: "completed", conclusion: "failure") }
    pending.times { CiCheckJob.create!(repo: repo, job_id: (id += 1), head_sha: sha, workflow_name: "CI", status: "in_progress") }
  end

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

  # One ingested CI job (workflow_job row) — distinct check name per call so the
  # latest-attempt fold counts it as its own check.
  def seed_check_job(repo:, sha:, workflow:, conclusion:, status: "completed", branch: "main")
    CiCheckJob.create!(repo: repo, job_id: SecureRandom.random_number(10**12), head_sha: sha,
                       head_branch: branch, workflow_name: workflow, status: status, conclusion: conclusion,
                       name: "#{workflow} #{SecureRandom.hex(3)}")
  end

  def seed_run(branch:, sha:, repo: "amcritchie/mcritchie-studio", workflow: "CI", started_at: Time.current)
    GithubWorkflowRun.create!(
      repo: repo, workflow_name: workflow,
      run_id: SecureRandom.random_number(10**12), status: "in_progress",
      head_branch: branch, head_sha: sha, run_started_at: started_at
    )
  end

  # A persisted active (assembling) release with one member task per repo, so
  # ordered_members/release_repo resolve real member repos for for_release.
  def release_with_members(*repos)
    rel = Release.open!(branch: "release/ci-tracks-#{SecureRandom.hex(3)}")
    repos.each_with_index do |repo, index|
      Task.create!(title: "member #{repo} #{SecureRandom.hex(2)}", stage: "reviewed",
                   position: (index + 1) * 10, release_slug: rel.slug,
                   metadata: { "devops" => { "repositories" => [repo] } })
    end
    rel
  end
end
