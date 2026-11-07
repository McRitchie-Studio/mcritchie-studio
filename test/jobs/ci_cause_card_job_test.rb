require "test_helper"

# [unit] CiCauseCardJob + Ci::CauseCard: a same-SHA red then green files one board card
# per cause, classed infra / harness / test / product, and folds every later
# occurrence of the same cause into that card (task deterministic-ci).
class CiCauseCardJobTest < ActiveJob::TestCase
  REPO = "McRitchie-Studio/mcritchie-studio"

  # A Github::Client double: the red attempt's jobs, then each job's log.
  class FakeClient
    def initialize(jobs:, logs:)
      @jobs = jobs
      @logs = logs
    end

    def get(path, params: {})
      raise "unexpected #{path}" unless path.end_with?("/jobs")

      { "jobs" => @jobs }
    end

    def get_text(path)
      @logs.fetch(path[%r{/jobs/(\d+)/logs\z}, 1].to_i)
    end
  end

  RAILS_LOG = <<~LOG
    2026-11-01T13:04:11.0000000Z Failure:
    2026-11-01T13:04:11.0000001Z ContactFlaggedDigestJobTest#test_old_flag [test/jobs/sample_digest_job_test.rb:38]:
    2026-11-01T13:04:11.0000002Z 0 emails expected, but 1 were sent.
    2026-11-01T13:04:11.0000003Z
  LOG
  APT_LOG = "2026-10-26T14:22:10.0000000Z ::error::apt-get failed every attempt\n"

  def jobs
    [
      { "id" => 11, "name" => "ci / rails (2)", "conclusion" => "failure", "head_sha" => "abc123", "html_url" => "https://example.test/j/11" },
      { "id" => 12, "name" => "ci / system", "conclusion" => "failure", "head_sha" => "abc123", "html_url" => "https://example.test/j/12" },
      { "id" => 13, "name" => "ci / rails_executed_set", "conclusion" => "failure", "head_sha" => "abc123" },
      { "id" => 14, "name" => "ci / static", "conclusion" => "success", "head_sha" => "abc123" }
    ]
  end

  def run_job(run_id: 500, attempt: 1, client: FakeClient.new(jobs: jobs, logs: { 11 => RAILS_LOG, 12 => APT_LOG, 13 => RAILS_LOG }))
    CiCauseCardJob.perform_now(REPO, run_id, attempt, 501, 1, client: client)
  end

  test "[unit] one card per cause, classed, at designed, with the occurrence on it" do
    assert_difference "Task.count", 2 do
      run_job
    end

    test_card = Task.find_by!(slug: "ci-cause-mcritchie-studio-contactflaggeddigestjobtest")
    assert_equal "designed", test_card.stage
    assert_equal "Find test cause ContactFlaggedDigestJobTest", test_card.title
    assert_equal "test", test_card.metadata.dig("ci_cause", "class")
    assert_equal "bug", test_card.devops["kind"]
    assert_equal ["mcritchie-studio"], test_card.devops["repositories"]
    occ = test_card.metadata.dig("ci_cause", "occurrences").sole
    assert_equal "500/1/11", occ["id"]
    assert_equal "abc123", occ["sha"]
    assert_includes occ["evidence"], "0 emails expected, but 1 were sent."
    assert_includes test_card.devops["agent_context"], "never a retry"

    infra = Task.find_by!(slug: "ci-cause-mcritchie-studio-apt-mirror")
    assert_equal "infra", infra.metadata.dig("ci_cause", "class")
  end

  test "[unit] a later occurrence folds into the open card, and a repeat folds nothing" do
    run_job
    assert_no_difference "Task.count" do
      run_job(run_id: 600)
      run_job(run_id: 600)
    end

    card = Task.find_by!(slug: "ci-cause-mcritchie-studio-contactflaggeddigestjobtest")
    assert_equal %w[500/1/11 600/1/11], card.metadata.dig("ci_cause", "occurrences").map { |o| o["id"] }
    assert_equal 2, card.metadata.dig("ci_cause", "count")
  end

  test "[unit] a cause that comes back after its card shipped opens a fresh card" do
    run_job
    Task.find_by!(slug: "ci-cause-mcritchie-studio-apt-mirror").update_columns(stage: "shipped")

    run_job(run_id: 700)
    assert Task.exists?(slug: "ci-cause-mcritchie-studio-apt-mirror-2")
    assert_equal 1, Task.find_by!(slug: "ci-cause-mcritchie-studio-contactflaggeddigestjobtest")
                        .metadata.dig("ci_cause", "occurrences").count { |o| o["id"].start_with?("700/") }
  end

  test "[unit] a GitHub read that fails costs this red its cards and leaves an ErrorLog row" do
    broken = Object.new
    def broken.get(*, **) = raise(Github::Client::HttpError, "GitHub API HTTP 404")

    assert_difference "ErrorLog.count", 1 do
      assert_no_difference("Task.count") { run_job(client: broken) }
    end
  end
end
