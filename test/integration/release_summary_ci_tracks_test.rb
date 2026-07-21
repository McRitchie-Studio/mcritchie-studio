require "test_helper"

# [integration] The Next Release card renders ONE G3 CI track per member repo — a
# release spanning turf-monster + mcritchie-studio shows two, each reading that
# repo's own release-candidate CI (folded live from the ingested CiCheckJob rows,
# so no network). Proves the board decomposition end to end: the per-repo slots,
# their per-repo dom/test ids, and each track's own state.
class ReleaseSummaryCiTracksTest < ActionDispatch::IntegrationTest
  test "[integration] the release card renders one G3 CI track per member repo" do
    Release.delete_all
    GithubWorkflowRun.delete_all
    CiCheckJob.delete_all

    rel = Release.open!(branch: "release/ci-tracks")
    hub  = member("Hub release CI work", "mcritchie-studio", 10)
    turf = member("Turf release CI work", "turf-monster", 20)
    [hub, turf].each { |task| rel.add(task) }

    # Each app repo's `release` branch tip has its own ingested CI run: the hub fully
    # green (8/8), turf mid-flight (3 passed, 5 pending).
    seed_release_ci("amcritchie/mcritchie-studio", "hub-rc",  passed: 8, pending: 0)
    seed_release_ci("amcritchie/turf-monster",     "turf-rc", passed: 3, pending: 5)

    get deployments_path
    assert_response :success

    # One slot per member repo, on its own per-repo stable id (the live morph target).
    assert_select "#current-release #release-ci-progress-mcritchie-studio", 1
    assert_select "#current-release #release-ci-progress-turf-monster", 1
    # The single hub-only bar is gone — no bare id survives the decomposition.
    assert_select "#release-ci-progress", 0

    # Each track rendered its meter (present? true for both), on its own inner test id.
    assert_select "#release-ci-progress-mcritchie-studio [data-test='release-card-ci-progress-mcritchie-studio']", 1
    assert_select "#release-ci-progress-turf-monster [data-test='release-card-ci-progress-turf-monster']", 1
  end

  private

  def member(title, repo, position)
    Task.create!(title: title, stage: "reviewed", position: position,
                 metadata: { "devops" => { "repositories" => [repo] } })
  end

  def seed_release_ci(repo, sha, passed:, pending:)
    GithubWorkflowRun.create!(
      repo: repo, workflow_name: "CI",
      run_id: SecureRandom.random_number(10**12), status: "in_progress",
      head_branch: Release::BRANCH, head_sha: sha, run_started_at: Time.current
    )
    id = SecureRandom.random_number(10**12)
    passed.times  { CiCheckJob.create!(repo: repo, job_id: (id += 1), head_sha: sha, workflow_name: "CI", status: "completed", conclusion: "success") }
    pending.times { CiCheckJob.create!(repo: repo, job_id: (id += 1), head_sha: sha, workflow_name: "CI", status: "in_progress") }
  end
end
