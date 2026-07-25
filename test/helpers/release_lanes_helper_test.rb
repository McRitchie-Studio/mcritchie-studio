require "test_helper"

# [unit] ApplicationHelper#release_repo_lanes — the per-repo /deployments tracker. One
# lane per member repo, each with four phase meters. The load-bearing invariant is that
# the QA/Deploying meters are gated by THIS release's own stage stamps (not a stray run
# for the repo), and Confirming is the coarse, release-grain meter.
class ReleaseLanesHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "[unit] one lane per member repo, apps vs libraries" do
    lanes = release_repo_lanes(lane_release("mcritchie-studio", "studio-engine"))

    assert_equal %w[mcritchie-studio studio-engine], lanes.map { |l| l[:repo] }.sort
    assert_equal "lib", lanes.find { |l| l[:repo] == "studio-engine" }[:kind]
    assert_equal "app", lanes.find { |l| l[:repo] == "mcritchie-studio" }[:kind]
    assert_equal 4, lanes.first[:phases].size, "four phase meters per lane"
  end

  test "[unit] deploy meters are gated by the release's OWN stage, not a stray run" do
    rel = lane_release("mcritchie-studio")
    # A completed QA Deploy run exists for the repo, but the release has NOT entered QA.
    GithubWorkflowRun.create!(repo: "amcritchie/mcritchie-studio", workflow_name: "QA Deploy", run_id: 8_100,
                              status: "completed", conclusion: "success", head_branch: "main", head_sha: "z",
                              run_started_at: Time.current, html_url: "https://github.com/amcritchie/mcritchie-studio/actions/runs/8100")
    states = ->(r) { release_repo_lanes(r).first[:phases].to_h { |p| [p[:key], p[:state]] } }

    s = states.call(rel)
    assert_equal :pending, s["qa_deploying"], "a stray run must NOT light QA before the release enters it"
    assert_equal :pending, s["confirming"]
    assert_equal :pending, s["production_deploying"]

    rel.stamp_stage!("qa_deploying")
    assert_equal :running, states.call(rel.reload)["qa_deploying"], "QA lights only once the release enters it"

    rel.stamp_stage!("qa_deployed")
    assert_equal :done, states.call(rel.reload)["qa_deploying"]

    rel.stamp_stage!("confirming")
    assert_equal :running, states.call(rel.reload)["confirming"], "Confirming is coarse, off the stamps"

    rel.stamp_stage!("prod_deploying")
    assert_equal :running, states.call(rel.reload)["production_deploying"]
  end

  test "[unit] a reached deploy meter carries the run link + flips to failed on a red run" do
    rel = lane_release("mcritchie-studio")
    rel.stamp_stage!("qa_deploying")
    GithubWorkflowRun.create!(repo: "amcritchie/mcritchie-studio", workflow_name: "QA Deploy", run_id: 8_200,
                              status: "completed", conclusion: "failure", head_branch: "main", head_sha: "z",
                              run_started_at: Time.current, html_url: "https://github.com/amcritchie/mcritchie-studio/actions/runs/8200")

    qa = release_repo_lanes(rel.reload).first[:phases].find { |p| p[:key] == "qa_deploying" }
    assert_equal :failed, qa[:state], "a completed-but-failed run flips the reached QA meter to failed"
    assert_equal "https://github.com/amcritchie/mcritchie-studio/actions/runs/8200", qa[:url]
  end

  test "[unit] a library shows Published, then n/a for the server-deploy phases" do
    phases = release_repo_lanes(lane_release("studio-engine")).first[:phases].to_h { |p| [p[:key], p] }

    assert_equal "Published", phases["published"][:label]
    assert_equal :na, phases["confirming"][:state]
    assert_equal :na, phases["deploying"][:state]
  end

  private

  def lane_release(*repos)
    rel = Release.open!
    repos.each_with_index do |repo, i|
      Task.create!(title: "member #{repo} #{SecureRandom.hex(2)}", stage: "reviewed", position: (i + 1) * 10,
                   release_slug: rel.slug, metadata: { "devops" => { "repositories" => [repo] } })
    end
    rel.reload
  end
end
