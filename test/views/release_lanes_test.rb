require "test_helper"

# [component] The per-repo lanes tracker (tasks/_release_lanes + _release_phase_meter).
# Pins: one lane per member repo; Assembling shows the G3 CI (fraction + check row) and
# links to its run; the deploy meters are GATED by the release's own stage (a stray run
# can't light a phase it hasn't entered) and link to their run once reached; Confirming
# runs as a coarse indeterminate bar; a library shows Published + n/a deploy phases.
class ReleaseLanesTest < ActionView::TestCase
  setup do
    GithubWorkflowRun.delete_all
    CiCheckJob.delete_all
  end

  test "[component] one lane per repo; Assembling shows CI + link; deploy meters gated pending" do
    rel = lane_release("mcritchie-studio", "turf-monster")
    seed_ci("amcritchie/mcritchie-studio", "release", "CI", "mcr", 8)
    # A completed QA Deploy run exists, but the release is still at Assembling — it must NOT light QA.
    seed_deploy("amcritchie/mcritchie-studio", "QA Deploy", "completed", "success", 9001)

    render partial: "tasks/release_lanes", locals: { release: rel }

    assert_select "[data-test='release-lane']", 2
    assert_select "[data-test='release-lane'] [data-test='release-phase-meter']", 8

    hub = "[data-test='release-lane'][data-repo='mcritchie-studio']"
    assert_select "#{hub} [data-phase='assembling'][data-state='done']", 1
    assert_select "#{hub} [data-phase='assembling'] a[data-test='release-phase-link']", 1, "Assembling links to its G3 run"
    assert_select "#{hub} [data-phase='assembling'] [data-test='release-phase-checks']", 1, "and shows a check row"
    assert_select "#{hub} [data-phase='qa_deploying'][data-state='pending']", 1, "a stray run cannot light QA before the release enters it"
    assert_select "#{hub} [data-phase='qa_deploying'] a", 0, "a pending meter has no link"
    assert_select "#{hub} [data-phase='confirming'][data-state='pending']", 1
    assert_select "#{hub} [data-phase='production_deploying'][data-state='pending']", 1
  end

  test "[component] a reached QA meter runs and links to its deploy run" do
    rel = lane_release("mcritchie-studio")
    rel.stamp_stage!("qa_deploying")
    seed_deploy("amcritchie/mcritchie-studio", "QA Deploy", "in_progress", nil, 9100,
                url: "https://github.com/amcritchie/mcritchie-studio/actions/runs/9100")

    render partial: "tasks/release_lanes", locals: { release: rel.reload }

    qa = "[data-repo='mcritchie-studio'] [data-phase='qa_deploying']"
    assert_select "#{qa}[data-state='running']", 1
    assert_select "#{qa} a[data-test='release-phase-link'][href='https://github.com/amcritchie/mcritchie-studio/actions/runs/9100']", 1
  end

  test "[component] the coarse Confirming meter runs as an indeterminate lavender bar" do
    rel = lane_release("mcritchie-studio")
    rel.stamp_stage!("qa_deployed")
    rel.stamp_stage!("confirming")

    render partial: "tasks/release_lanes", locals: { release: rel.reload }

    conf = "[data-repo='mcritchie-studio'] [data-phase='confirming']"
    assert_select "#{conf}[data-state='running']", 1
    assert_select "#{conf} .release-meter-indeterminate", 1, "the coarse gate animates as an indeterminate bar"
  end

  test "[component] a library lane shows Published + n/a for the deploy phases" do
    rel = lane_release("studio-engine")
    seed_ci("amcritchie/studio-engine", "main", "Engine CI", "eng", 5)

    render partial: "tasks/release_lanes", locals: { release: rel.reload }

    lib = "[data-test='release-lane'][data-repo='studio-engine'][data-kind='lib']"
    assert_select "#{lib} [data-phase='published'][data-state='done']", 1
    assert_select "#{lib} [data-phase='confirming'][data-state='na']", 1
    assert_select "#{lib} [data-phase='deploying'][data-state='na']", 1
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

  def seed_ci(nwo, branch, workflow, sha, passed)
    GithubWorkflowRun.create!(repo: nwo, workflow_name: workflow, run_id: SecureRandom.random_number(10**12),
                              status: "in_progress", head_branch: branch, head_sha: sha, run_started_at: Time.current,
                              html_url: "https://github.com/#{nwo}/actions/runs/1")
    passed.times do
      CiCheckJob.create!(repo: nwo, job_id: SecureRandom.random_number(10**12), head_sha: sha, head_branch: branch,
                         workflow_name: workflow, status: "completed", conclusion: "success", name: "check")
    end
  end

  def seed_deploy(nwo, workflow, status, conclusion, rid, url: nil)
    GithubWorkflowRun.create!(repo: nwo, workflow_name: workflow, run_id: rid, status: status, conclusion: conclusion,
                              head_branch: "main", head_sha: "d#{rid}", run_started_at: Time.current,
                              html_url: url || "https://github.com/#{nwo}/actions/runs/#{rid}")
  end
end
