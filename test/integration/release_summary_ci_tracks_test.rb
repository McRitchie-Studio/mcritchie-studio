require "test_helper"

# [integration] The Next Release card shows each member repo's G3 CI — now as the
# ASSEMBLING meter of that repo's lane (the standalone "<repo> G3 tests" bars were
# retired; the same reader, release_ci_progress, feeds the meter). A release spanning
# mcritchie-studio + turf-monster shows two lanes, each Assembling meter reading that
# repo's own release-candidate CI (folded live from the ingested CiCheckJob rows) and
# linking to its Actions run when there is one.
class ReleaseSummaryCiTracksTest < ActionDispatch::IntegrationTest
  test "[integration] each member lane's Assembling meter reads that repo's G3 CI, linked to the run" do
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
    seed_release_ci("McRitchie-Studio/mcritchie-studio", "hub-rc",  passed: 8, pending: 0,
                    html_url: "https://github.com/McRitchie-Studio/mcritchie-studio/actions/runs/5100")
    seed_release_ci("McRitchie-Studio/turf-monster",     "turf-rc", passed: 3, pending: 5)

    get deployments_path
    assert_response :success

    hub_lane  = "#current-release [data-test='release-lane'][data-repo='mcritchie-studio']"
    turf_lane = "#current-release [data-test='release-lane'][data-repo='turf-monster']"

    # One lane per member repo; the retired standalone G3 bars leave no slot behind.
    assert_select hub_lane, 1
    assert_select turf_lane, 1
    assert_select "#current-release [data-test='release-card-ci-progress-mcritchie-studio']", 0,
                  "the standalone G3 bars are gone — CI lives in the Assembling meter now"

    # The hub's Assembling meter is DONE (8/8) and links its label to that G3 Actions run
    # in a new tab (noopener), named for screen readers.
    assert_select "#{hub_lane} [data-phase='assembling'][data-state='done']", 1
    hub_link = "#{hub_lane} [data-phase='assembling'] a[data-test='release-phase-link']"
    assert_select "#{hub_link}[href='https://github.com/McRitchie-Studio/mcritchie-studio/actions/runs/5100']", 1
    assert_select "#{hub_link}[target='_blank'][rel='noopener'][title]", 1

    # turf's Assembling meter is RUNNING (3 of 8) with NO run url, so it stays UNLINKED —
    # a plain meter, never a broken href="#".
    assert_select "#{turf_lane} [data-phase='assembling'][data-state='running']", 1
    assert_select "#{turf_lane} [data-phase='assembling'] a", 0, "no run url -> no link"
    assert_select "#current-release a[href='#']", 0, "never a broken href on any lane"
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
