require "test_helper"

# [unit] Ci::CauseSweep: CI history → one CiCauseCardJob per same-SHA red a later run
# proved green, including the red a passing re-run hides (task deterministic-ci).
class Ci::CauseSweepTest < ActiveJob::TestCase
  class FakeClient
    attr_reader :paths

    def initialize = @paths = []

    def get(path, params: {})
      @paths << path
      case path
      when %r{/actions/runs\z}
        return { "workflow_runs" => [] } if params[:page] > 1

        { "workflow_runs" => [
          { "id" => 1, "run_attempt" => 2, "conclusion" => "success", "head_sha" => "a", "name" => "CI", "event" => "pull_request" },
          { "id" => 2, "run_attempt" => 1, "conclusion" => "failure", "head_sha" => "b", "name" => "CI", "event" => "pull_request" },
          { "id" => 3, "run_attempt" => 1, "conclusion" => "success", "head_sha" => "b", "name" => "CI", "event" => "pull_request" },
          { "id" => 4, "run_attempt" => 1, "conclusion" => "failure", "head_sha" => "c", "name" => "CI", "event" => "schedule" },
          { "id" => 5, "run_attempt" => 1, "conclusion" => "success", "head_sha" => "c", "name" => "CI", "event" => "pull_request" }
        ] }
      when %r{/runs/1/attempts/1\z} then { "conclusion" => "failure" }
      else raise "unexpected #{path}"
      end
    end
  end

  test "[unit] enqueues the re-run's hidden red and the second run's red, never a schedule's" do
    client = FakeClient.new
    flips = nil
    assert_enqueued_jobs 2, only: CiCauseCardJob do
      flips = Ci::CauseSweep.call(repo: "o/r", days: 7, client: client)
    end
    assert_equal [[1, 1], [2, 1]], flips.map { |f| [f[:red][:run_id], f[:red][:attempt]] }.sort
  end

  test "[unit] a dry run enqueues nothing" do
    assert_no_enqueued_jobs(only: CiCauseCardJob) { Ci::CauseSweep.call(repo: "o/r", client: FakeClient.new, dry_run: true) }
  end
end
