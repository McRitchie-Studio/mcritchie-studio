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
end
