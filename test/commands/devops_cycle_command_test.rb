require "test_helper"
require "json"
require "open3"
require "rbconfig"

class DevopsCycleCommandTest < ActiveSupport::TestCase
  def setup
    @script = Rails.root.join("bin/devops-cycle").to_s
    @fixture = Rails.root.join("test/fixtures/files/devops_cycle_snapshot.json").to_s
  end

  test "prints stage queues with task and qa-intake context" do
    out, err, status = devops_cycle

    assert status.success?, err
    assert_includes out, "DevOps Cycle Snapshot"
    assert_includes out, "PR Review (3)"
    assert_includes out, "QA Review (1)"
    assert_includes out, "Prod Ready (1)"
    assert_includes out, "Ship sidebar recovery (task-pr123)"
    assert_includes out, "https://www.mcritchie.studio/tasks/task-pr123"
    assert_includes out, "qa-intake: avi-ready amcritchie/mcritchie-studio#123"
    assert_includes out, "latest qa_feedback: Needs one more navbar regression test before merge."
  end

  test "prints machine-readable enriched task JSON" do
    out, err, status = devops_cycle("--json")

    assert status.success?, err
    snapshot = JSON.parse(out)
    assert_equal 5, snapshot.dig("summary", "tasks")
    task = snapshot.fetch("tasks").find { |item| item.fetch("slug") == "task-qa456" }
    assert_equal "https://qa.turfmonster.media/contests/test", task.dig("devops", "qa_url")
    assert_equal "checks-review", task.dig("qa_intake", "status")
    assert_equal "handoff", task.dig("latest_activity", "activity_type")
  end

  test "prints batch plan for parallel blocked serialized and release lanes" do
    out, err, status = devops_cycle("--plan")

    assert status.success?, err
    assert_includes out, "Batch Plan"
    assert_includes out, "Parallel PR Review (1)"
    assert_includes out, "Serialized / Conductor Review (1)"
    assert_includes out, "Blocked / Return To Agent (1)"
    assert_includes out, "QA Review (1)"
    assert_includes out, "Production Ready (1)"
    assert_includes out, "task-engine789 Ship shared engine table headers"
    assert_includes out, "reason=multiple repositories: studio-engine + turf-monster"
    assert_includes out, "task-block000 Fix stale worktree handoff"
    assert_includes out, "owner=feature_agent"
  end

  test "includes batch plan in JSON when requested" do
    out, err, status = devops_cycle("--json", "--plan")

    assert status.success?, err
    snapshot = JSON.parse(out)
    assert_equal 1, snapshot.dig("plan", "summary", "parallel_pr_review")
    assert_equal 1, snapshot.dig("plan", "summary", "serialized_pr_review")
    assert_equal 1, snapshot.dig("plan", "summary", "blocked_or_return")
    assert_equal 1, snapshot.dig("plan", "summary", "qa_review")
    assert_equal 1, snapshot.dig("plan", "summary", "production_ready")

    blocked = snapshot.dig("plan", "groups").find { |group| group.fetch("key") == "blocked_or_return" }
    assert_equal "task-block000", blocked.fetch("tasks").first.fetch("slug")
    assert_equal "feature_agent", blocked.fetch("tasks").first.fetch("owner")
  end

  test "prints scout packets for reviewable PR lanes" do
    out, err, status = devops_cycle("--scout-packets")

    assert status.success?, err
    assert_includes out, "Scout Packets (2)"
    assert_includes out, "scout-task-pr123 Ship sidebar recovery"
    assert_includes out, "mode=parallel_scout reason=standard PR review"
    assert_includes out, "scout-task-engine789 Ship shared engine table headers"
    assert_includes out, "mode=serialized_scout reason=multiple repositories: studio-engine + turf-monster"
    assert_includes out, "Do not merge, deploy, publish gems, change provider config, rotate credentials, or force-push."
    assert_includes out, "Recommend one outcome to Avi: merge-ready, wait-for-CI, request-changes, or conductor-review."
  end

  test "includes scout packets in JSON when requested" do
    out, err, status = devops_cycle("--json", "--scout-packets")

    assert status.success?, err
    snapshot = JSON.parse(out)
    assert_equal 2, snapshot.fetch("scout_packets").size
    assert_equal 1, snapshot.dig("plan", "summary", "parallel_pr_review")

    parallel = snapshot.fetch("scout_packets").find { |packet| packet.fetch("packet_id") == "scout-task-pr123" }
    assert_equal "parallel_scout", parallel.fetch("mode")
    assert_equal "https://github.com/amcritchie/mcritchie-studio/pull/123", parallel.dig("devops", "pr_url")
    assert_includes parallel.fetch("guardrails"), "Do not merge PRs."
    assert_includes parallel.fetch("prompt"), "Work from /Users/alex/projects as an Avi review scout for task-pr123."
    assert_includes parallel.fetch("prompt"), "Return a concise scout report with file/line references where applicable."

    slugs = snapshot.fetch("scout_packets").map { |packet| packet.dig("task", "slug") }
    refute_includes slugs, "task-block000"
    refute_includes slugs, "task-qa456"
    refute_includes slugs, "task-prod999"
  end

  private

  def devops_cycle(*args)
    Open3.capture3(
      RbConfig.ruby,
      @script,
      "--offline-fixture",
      @fixture,
      *args,
      chdir: Rails.root.to_s
    )
  end
end
