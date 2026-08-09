# frozen_string_literal: true

require "test_helper"

module Ci
  # [unit] Ci::RunReconciler — the post-deploy heal for rows the FIRST-WRITE-WINS
  # conclusion bug corrupted. The ingest fix is forward-only (GitHub has already
  # delivered both attempts and will not re-deliver), so without this pass the
  # motivating PR stays unclaimable and the release CI lane stays red.
  class RunReconcilerTest < ActiveSupport::TestCase
    REPO = "McRitchie-Studio/mcritchie-studio"

    setup { GithubWorkflowRun.delete_all }

    # A client whose #get answers from a run_id → payload map, so no HTTP happens.
    class StubClient
      attr_reader :calls

      def initialize(runs, raise_for: nil)
        @runs = runs
        @raise_for = raise_for
        @calls = []
      end

      def get(path)
        run_id = path[%r{/actions/runs/(\d+)}, 1].to_i
        @calls << run_id
        raise Github::Client::HttpError, "HTTP 404" if @raise_for == run_id

        @runs.fetch(run_id)
      end
    end

    def seed(run_id:, conclusion:, run_attempt: nil, status: "completed", branch: "feat/x")
      GithubWorkflowRun.create!(repo: REPO, workflow_name: "CI", run_id: run_id, status: status,
                                conclusion: conclusion, run_attempt: run_attempt,
                                head_branch: branch, head_sha: "sha#{run_id}", run_started_at: Time.current)
    end

    def remote(status: "completed", conclusion: "success", run_attempt: 2)
      { "status" => status, "conclusion" => conclusion, "run_attempt" => run_attempt }
    end

    # The real incident: run 31276835993 read `failure` here while the Actions API
    # reported attempt 2 / success, so PR #727 was green on GitHub and unclaimable.
    test "[unit] a row stuck at the pre-re-run failure is corrected from GitHub" do
      record = seed(run_id: 31_276_835_993, conclusion: "failure")
      client = StubClient.new({ 31_276_835_993 => remote })

      result = Ci::RunReconciler.call(client: client)

      assert_equal 1, result.corrected
      assert_equal "success", record.reload.conclusion
      assert_equal 2, record.run_attempt
    end

    test "[unit] a row that already agrees with GitHub is left alone" do
      record = seed(run_id: 42, conclusion: "success", run_attempt: 2)
      client = StubClient.new({ 42 => remote })

      result = Ci::RunReconciler.call(client: client)

      assert_equal 0, result.corrected
      assert_equal 1, result.checked
      assert_no_changes -> { record.reload.updated_at } do
        Ci::RunReconciler.call(client: client)
      end
    end

    test "[unit] idempotent — a second pass corrects nothing" do
      seed(run_id: 7, conclusion: "failure")
      client = StubClient.new({ 7 => remote })

      assert_equal 1, Ci::RunReconciler.call(client: client).corrected
      assert_equal 0, Ci::RunReconciler.call(client: client).corrected
    end

    test "[unit] DRY_RUN reports the correction without writing it" do
      record = seed(run_id: 8, conclusion: "failure")
      client = StubClient.new({ 8 => remote })

      result = Ci::RunReconciler.call(client: client, dry_run: true)

      assert_equal 1, result.corrected
      assert_equal "failure", record.reload.conclusion, "a dry run must not write"
    end

    # GitHub is authoritative but never invents: a run still in flight remotely has
    # no verdict to copy, and a blank conclusion must not blank ours.
    test "[unit] a remotely-unfinished run is not touched" do
      record = seed(run_id: 9, conclusion: "failure")
      client = StubClient.new({ 9 => remote(status: "in_progress", conclusion: nil) })

      assert_equal 0, Ci::RunReconciler.call(client: client).corrected
      assert_equal "failure", record.reload.conclusion
    end

    # One unreadable run (deleted, moved org, rate-limited) must not abort the pass
    # — this is a deploy step, and a partial heal beats a failed release.
    test "[unit] an unreadable run is counted and skipped, not raised" do
      seed(run_id: 10, conclusion: "failure")
      healthy = seed(run_id: 11, conclusion: "failure")
      client = StubClient.new({ 11 => remote }, raise_for: 10)

      result = Ci::RunReconciler.call(client: client)

      assert_equal 1, result.unreadable
      assert_equal 1, result.corrected
      assert_equal "success", healthy.reload.conclusion, "the pass continues past a bad row"
    end

    test "[unit] non-terminal rows are never candidates — GitHub will still deliver" do
      seed(run_id: 12, conclusion: nil, status: "in_progress")
      client = StubClient.new({})

      result = Ci::RunReconciler.call(client: client)

      assert_equal 0, result.checked
      assert_empty client.calls, "an in-flight row must not cost an API call"
    end

    test "[unit] rows older than the window are not checked" do
      seed(run_id: 13, conclusion: "failure").update_column(:created_at, 90.days.ago)
      client = StubClient.new({})

      assert_equal 0, Ci::RunReconciler.call(client: client, days: 30).checked
    end
  end
end
