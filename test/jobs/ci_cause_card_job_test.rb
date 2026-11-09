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
  CENSUS_LOG = <<~LOG
    2026-11-09T05:34:28.6629823Z RAILS EXECUTED SET: RED
    2026-11-09T05:34:28.6637151Z   · missing receipts for shard(s) 2 of 4
    2026-11-09T05:34:28.6681456Z ##[error]Process completed with exit code 1.
  LOG
  SETUP_504 = File.read(Rails.root.join("test/fixtures/files/ci_cause_2026_11_09/voicebox__scan-js.log"))

  def jobs
    [
      { "id" => 11, "name" => "ci / rails (2)", "conclusion" => "failure", "head_sha" => "abc123", "html_url" => "https://example.test/j/11" },
      { "id" => 12, "name" => "ci / system", "conclusion" => "failure", "head_sha" => "abc123", "html_url" => "https://example.test/j/12" },
      { "id" => 13, "name" => "ci / rails_executed_set", "conclusion" => "failure", "head_sha" => "abc123" },
      { "id" => 14, "name" => "ci / static", "conclusion" => "success", "head_sha" => "abc123" },
      { "id" => 15, "name" => "ci / rails (4)", "conclusion" => "cancelled", "head_sha" => "abc123" }
    ]
  end

  def run_job(run_id: 500, attempt: 1, client: FakeClient.new(jobs: jobs, logs: { 11 => RAILS_LOG, 12 => APT_LOG, 13 => CENSUS_LOG }))
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
    occ, census = test_card.metadata.dig("ci_cause", "occurrences")
    assert_equal "500/1/11", occ["id"]
    assert_equal "abc123", occ["sha"]
    assert_equal REPO, occ["repo"]
    assert_includes occ["evidence"], "0 emails expected, but 1 were sent."
    assert_includes test_card.devops["agent_context"], "never a retry"
    # The census that missed shard 2 is a follow-on of rails (2)'s cause, no card of its own.
    assert_equal ["500/1/13", "ci / rails (2)"], census.values_at("id", "follows")

    infra = Task.find_by!(slug: "ci-cause-infra-apt-mirror")
    assert_equal "infra", infra.metadata.dig("ci_cause", "class")
    refute Task.exists?(slug: "ci-cause-mcritchie-studio-job-ci-rails-executed-set")
    refute(Task.where("slug LIKE 'ci-cause-%rails-4%'").exists?, "a cancelled sibling files nothing")
  end

  test "[unit] a later occurrence folds into the open card, and a repeat folds nothing" do
    run_job
    assert_no_difference "Task.count" do
      run_job(run_id: 600)
      run_job(run_id: 600)
    end

    card = Task.find_by!(slug: "ci-cause-mcritchie-studio-contactflaggeddigestjobtest")
    assert_equal %w[500/1/11 500/1/13 600/1/11 600/1/13], card.metadata.dig("ci_cause", "occurrences").map { |o| o["id"] }
    assert_equal 4, card.metadata.dig("ci_cause", "count")
  end

  test "[unit] a cause that comes back after its card shipped opens a fresh card" do
    run_job
    Task.find_by!(slug: "ci-cause-infra-apt-mirror").update_columns(stage: "shipped")

    run_job(run_id: 700)
    assert Task.exists?(slug: "ci-cause-infra-apt-mirror-2")
    assert_equal 2, Task.find_by!(slug: "ci-cause-mcritchie-studio-contactflaggeddigestjobtest")
                        .metadata.dig("ci_cause", "occurrences").count { |o| o["id"].start_with?("700/") }
  end

  test "[unit] a GitHub read that fails costs this red its cards and leaves an ErrorLog row" do
    broken = Object.new
    def broken.get(*, **) = raise(Github::Client::HttpError, "GitHub API HTTP 404")

    assert_difference "ErrorLog.count", 1 do
      assert_no_difference("Task.count") { run_job(client: broken) }
    end
  end

  test "[unit] one setup-ruby 504 across repos is ONE card, each job an occurrence naming its repo" do
    one = [{ "id" => 21, "name" => "scan-js", "conclusion" => "failure", "head_sha" => "f00d" }]
    assert_difference "Task.count", 1 do
      %w[McRitchie-Studio/voicebox McRitchie-Studio/cyvasse McRitchie-Studio/turf-monster].each_with_index do |repo, i|
        CiCauseCardJob.perform_now(repo, 900 + i, 1, 950, 1, client: FakeClient.new(jobs: one, logs: { 21 => SETUP_504 }))
      end
    end

    card = Task.find_by!(slug: "ci-cause-infra-toolchain-download")
    assert_equal "Find infra cause toolchain-download", card.title
    assert_equal %w[voicebox cyvasse turf-monster], card.devops["repositories"]
    assert_equal 3, card.metadata.dig("ci_cause", "count")
    assert_equal %w[McRitchie-Studio/voicebox McRitchie-Studio/cyvasse McRitchie-Studio/turf-monster],
                 card.metadata.dig("ci_cause", "occurrences").map { |o| o["repo"] }
    assert_includes card.description, "Outside every repo"
  end

  test "[unit] a red job with no ##[error] line files no card and leaves one ErrorLog row" do
    one = [{ "id" => 31, "name" => "ci / static", "conclusion" => "failure", "head_sha" => "beef", "html_url" => "https://example.test/j/31" }]
    client = FakeClient.new(jobs: one, logs: { 31 => "2026-11-09T00:00:00Z Post job cleanup.\n" })
    assert_difference "ErrorLog.count", 1 do
      assert_no_difference("Task.count") { 2.times { run_job(client: client) } }
    end
    assert_includes ErrorLog.last.message, "ci / static (500/1/31)"
  end

  test "[unit] a create that loses the slug race folds into the card that won" do
    run_job
    card = Task.find_by!(slug: "ci-cause-infra-apt-mirror")
    filer = Ci::CauseCard.new(REPO, { klass: "infra", key: "apt-mirror", evidence: ["x"] },
                              { "id" => "800/1/12", "repo" => REPO })
    # As a second job sees it before the winner's insert: no open card, the base free.
    stale = true
    filer.define_singleton_method(:open_card) { |base| stale ? (stale = false) || nil : super(base) }
    filer.define_singleton_method(:next_free_slug) { |base| base }

    assert_no_difference("Task.count") { filer.file! }
    assert_equal %w[500/1/12 800/1/12], card.reload.metadata.dig("ci_cause", "occurrences").map { |o| o["id"] }
  end
end
