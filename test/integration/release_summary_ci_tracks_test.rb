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
    # green (8/8) WITH an Actions-run html_url, turf mid-flight (3 passed, 5 pending)
    # with NO html_url (the graceful-unlinked case below).
    seed_release_ci("amcritchie/mcritchie-studio", "hub-rc",  passed: 8, pending: 0,
                    html_url: "https://github.com/amcritchie/mcritchie-studio/actions/runs/5100")
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

    # ASK 1 — the relabel: each track LEADS with the app emoji, then the app (repo)
    # slug, then "G3 tests" (not the old "G3 CI 🐊").
    assert_select "#release-ci-progress-mcritchie-studio span", text: /mcritchie-studio G3 tests/
    assert_select "#release-ci-progress-turf-monster span", text: /turf-monster G3 tests/

    # ASK 2 — clickable: the hub track's run carries an html_url, so its whole meter
    # card is an anchor opening that Actions run in a NEW TAB (noopener), named for
    # screen readers.
    hub_link = "#release-ci-progress-mcritchie-studio a.ci-progress-card[data-test='release-card-ci-progress-mcritchie-studio']"
    assert_select "#{hub_link}[href='https://github.com/amcritchie/mcritchie-studio/actions/runs/5100']", 1
    assert_select "#{hub_link}[target='_blank'][rel='noopener']", 1
    assert_select "#{hub_link}[aria-label]", 1, "the link has an accessible name"

    # Graceful no-op: turf's run has NO html_url, so its track renders the meter but
    # UNLINKED — a plain panel, and NEVER a broken href="#".
    assert_select "#release-ci-progress-turf-monster div.ci-progress-card[data-test='release-card-ci-progress-turf-monster']", 1
    assert_select "#release-ci-progress-turf-monster a", 0, "no run url -> no link"
    assert_select "#current-release a[href='#']", 0, "never a broken href on any track"
  end

  private

  def member(title, repo, position)
    Task.create!(title: title, stage: "reviewed", position: position,
                 metadata: { "devops" => { "repositories" => [repo] } })
  end

  def seed_release_ci(repo, sha, passed:, pending:, html_url: nil)
    GithubWorkflowRun.create!(
      repo: repo, workflow_name: "CI",
      run_id: SecureRandom.random_number(10**12), status: "in_progress",
      head_branch: Release::BRANCH, head_sha: sha, run_started_at: Time.current, html_url: html_url
    )
    id = SecureRandom.random_number(10**12)
    passed.times  { CiCheckJob.create!(repo: repo, job_id: (id += 1), head_sha: sha, workflow_name: "CI", status: "completed", conclusion: "success") }
    pending.times { CiCheckJob.create!(repo: repo, job_id: (id += 1), head_sha: sha, workflow_name: "CI", status: "in_progress") }
  end
end
