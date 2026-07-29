require "test_helper"

# [unit] The two lists of CI-suite workflow names must not drift apart:
#   * GithubWorkflowRun::CI_PROGRESS_WORKFLOWS — which workflows the INGEST records
#     CiCheckJob rows for (the live progress source).
#   * Ci::ProgressReader::GEM_CI_WORKFLOWS — which workflow a GEM's track SELECTS
#     and SCOPES its fold to.
#
# If a gem's workflow is selected by the reader but NOT recorded by the ingest, its
# track has no live rows and — because a workflow-scoped read refuses the blind API —
# renders permanently blank. This test fails the moment a gem workflow is added to
# one list without the other.
class CiProgressWorkflowConsistencyTest < ActiveSupport::TestCase
  test "[unit] every gem CI workflow the reader selects is one the ingest records" do
    Ci::ProgressReader::GEM_CI_WORKFLOWS.each_value do |workflow|
      next if workflow.nil? # an unmapped gem resolves nothing — nothing to ingest

      assert_includes GithubWorkflowRun::CI_PROGRESS_WORKFLOWS, workflow,
                      "gem workflow #{workflow.inspect} is selected by Ci::ProgressReader but not in " \
                      "GithubWorkflowRun::CI_PROGRESS_WORKFLOWS, so the ingest records no rows for it — its " \
                      "track would render permanently blank"
    end
  end

  test "[unit] the app CI workflow is recorded" do
    assert_includes GithubWorkflowRun::CI_PROGRESS_WORKFLOWS, GithubWorkflowRun::CI_WORKFLOW
  end

  # ── The property, not the spellings ───────────────────────────────────────────
  #
  # The two tests above compare two LISTS, which is exactly why they did not catch
  # the real bug: Ci::ReviewGate was in neither list. It hard-coded the literal "CI"
  # for every repo, so a studio-engine PR resolved zero runs, read :none, and was
  # permanently unclaimable by pr-review — while both lists stayed perfectly in sync.
  #
  # So assert the PROPERTY instead: every repo the board can review must resolve to a
  # workflow the ingest actually records. A new gem added to config/release_repos.yml
  # without a workflow mapping fails here, at the registry, rather than silently
  # stranding its PRs.
  test "[unit] every registered repo resolves to a CI workflow the ingest records" do
    repos = Release::Repos.gem_repos + Release::Repos.app_repos
    refute_empty repos, "the repo registry is empty — this guard would be vacuous"

    repos.each do |repo|
      workflow = GithubWorkflowRun.ci_workflow_for(repo)
      next if workflow.nil? && Release::Repos.gem?(repo) # documented: unmapped gem = any workflow

      assert_includes GithubWorkflowRun::CI_PROGRESS_WORKFLOWS, workflow,
                      "#{repo} resolves CI workflow #{workflow.inspect}, which the ingest never records — " \
                      "its PRs would read :none and never be claimable for review"
    end
  end

  test "[unit] a gem repo does not resolve the app CI workflow name" do
    gems = Release::Repos.gem_repos.select { |r| GithubWorkflowRun::GEM_CI_WORKFLOWS.key?(r) }
    refute_empty gems, "no mapped gem repos — this guard would be vacuous"

    gems.each do |repo|
      refute_equal GithubWorkflowRun::CI_WORKFLOW, GithubWorkflowRun.ci_workflow_for(repo),
                   "#{repo} is a gem; resolving the app's plain #{GithubWorkflowRun::CI_WORKFLOW.inspect} " \
                   "workflow is the exact defect that made every gem PR unclaimable"
    end
  end
end
