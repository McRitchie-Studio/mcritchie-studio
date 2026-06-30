require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tempfile"

class DevopsCycleCommandTest < ActiveSupport::TestCase
  def setup
    @script = Rails.root.join("bin/devops-cycle").to_s
    @fixture = Rails.root.join("test/fixtures/files/devops_cycle_snapshot.json").to_s
  end

  test "prints stage queues with task and qa-intake context" do
    out, err, status = devops_cycle

    assert status.success?, err
    assert_includes out, "DevOps Cycle Snapshot"
    assert_includes out, "Submitted (4)"
    assert_includes out, "Reviewed (1)"
    assert_includes out, "Assembled (1)"
    assert_includes out, "Ship sidebar recovery (task-pr123)"
    assert_includes out, "https://www.mcritchie.studio/tasks/task-pr123"
    assert_includes out, "qa-intake: avi-ready amcritchie/mcritchie-studio#123"
    assert_includes out, "latest qa_feedback: Needs one more navbar regression test before merge."
  end

  test "prints machine-readable enriched task JSON" do
    out, err, status = devops_cycle("--json")

    assert status.success?, err
    snapshot = JSON.parse(out)
    assert_equal 6, snapshot.dig("summary", "tasks")
    task = snapshot.fetch("tasks").find { |item| item.fetch("slug") == "task-qa456" }
    assert_equal "https://qa.turfmonster.media/contests/test", task.dig("devops", "qa_url")
    assert_equal "checks-review", task.dig("qa_intake", "status")
    assert_equal "handoff", task.dig("latest_activity", "activity_type")
  end

  test "prints batch plan for parallel blocked serialized and release lanes" do
    out, err, status = devops_cycle("--plan")

    assert status.success?, err
    assert_includes out, "Batch Plan"
    assert_includes out, "Parallel Review (2)"
    assert_includes out, "Serialized / Conductor Review (1)"
    assert_includes out, "Blocked / Return To Agent (1)"
    assert_includes out, "Ready To Assemble (1)"
    assert_includes out, "Assembled Release (1)"
    assert_includes out, "task-engine789 Ship shared engine table headers"
    assert_includes out, "reason=multiple repositories: studio-engine + turf-monster"
    assert_includes out, "task-block000 Fix stale worktree handoff"
    assert_includes out, "owner=feature_agent"
  end

  test "includes batch plan in JSON when requested" do
    out, err, status = devops_cycle("--json", "--plan")

    assert status.success?, err
    snapshot = JSON.parse(out)
    assert_equal 2, snapshot.dig("plan", "summary", "parallel_review")
    assert_equal 1, snapshot.dig("plan", "summary", "serialized_review")
    assert_equal 1, snapshot.dig("plan", "summary", "blocked_or_return")
    assert_equal 1, snapshot.dig("plan", "summary", "ready_to_assemble")
    assert_equal 1, snapshot.dig("plan", "summary", "assembled_release")

    blocked = snapshot.dig("plan", "groups").find { |group| group.fetch("key") == "blocked_or_return" }
    assert_equal "task-block000", blocked.fetch("tasks").first.fetch("slug")
    assert_equal "feature_agent", blocked.fetch("tasks").first.fetch("owner")
  end

  test "prints scout packets for reviewable PR lanes" do
    out, err, status = devops_cycle("--scout-packets")

    assert status.success?, err
    assert_includes out, "Scout Packets (3)"
    assert_includes out, "scout-task-pr123 Ship sidebar recovery"
    assert_includes out, "scout-task-ready222 Ship focused DevOps helper"
    assert_includes out, "mode=parallel_scout reason=standard PR review"
    assert_includes out, "scout-task-engine789 Ship shared engine table headers"
    assert_includes out, "mode=serialized_scout reason=multiple repositories: studio-engine + turf-monster"
    assert_includes out, "Do not merge, deploy, publish gems, change provider config, rotate credentials, or force-push."
    assert_includes out, "Recommend one outcome to Avi: merge-ready, wait-for-CI, request-changes, or conductor-review."
    assert_includes out, "bin/devops-cycle --record-scout-report task-pr123 --outcome"
    assert_includes out, "Remove --dry-run only after the payload looks right."
  end

  test "includes scout packets in JSON when requested" do
    out, err, status = devops_cycle("--json", "--scout-packets")

    assert status.success?, err
    snapshot = JSON.parse(out)
    assert_equal 3, snapshot.fetch("scout_packets").size
    assert_equal 2, snapshot.dig("plan", "summary", "parallel_review")

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

  test "writes scout packet prompt files and manifest" do
    dir = Rails.root.join("tmp/devops-cycle-scouts-test").to_s
    FileUtils.rm_rf(dir)

    out, err, status = devops_cycle("--write-scout-packets", dir)

    assert status.success?, err
    assert_includes out, "Scout Launcher"
    assert_includes out, "count=3"
    assert_includes out, "task-pr123--parallel_scout.prompt"
    refute_includes out, "Scout Packets (3)"

    manifest_path = File.join(dir, "manifest.json")
    assert File.exist?(manifest_path), "expected #{manifest_path} to exist"
    manifest = JSON.parse(File.read(manifest_path))
    assert_equal dir, manifest.fetch("directory")
    assert_equal 3, manifest.fetch("count")

    prompt_paths = manifest.fetch("packets").map { |packet| packet.fetch("prompt_path") }
    assert_includes prompt_paths, File.join(dir, "task-pr123--parallel_scout.prompt")
    prompt = File.read(File.join(dir, "task-pr123--parallel_scout.prompt"))
    assert_includes prompt, "Work from /Users/alex/projects as an Avi review scout for task-pr123."
    assert_includes prompt, "Record your scout report on the task when complete:"
  ensure
    FileUtils.rm_rf(dir)
  end

  test "includes scout launcher manifest in JSON when writing prompts" do
    dir = Rails.root.join("tmp/devops-cycle-scouts-json-test").to_s
    FileUtils.rm_rf(dir)

    out, err, status = devops_cycle("--json", "--write-scout-packets", dir)

    assert status.success?, err
    snapshot = JSON.parse(out)
    launcher = snapshot.fetch("scout_launcher")
    assert_equal dir, launcher.fetch("directory")
    assert_equal File.join(dir, "manifest.json"), launcher.fetch("manifest_path")
    assert_equal 3, launcher.fetch("count")
    assert_equal 3, snapshot.fetch("scout_packets").size
    assert File.exist?(File.join(dir, "manifest.json")), "expected manifest to exist"
  ensure
    FileUtils.rm_rf(dir)
  end

  test "prints scout run control from a manifest" do
    dir = Rails.root.join("tmp/devops-cycle-scout-runs-test").to_s
    FileUtils.rm_rf(dir)
    devops_cycle("--write-scout-packets", dir)

    out, err, status = devops_cycle("--scout-runs", dir, "--max-scouts", "2")

    assert status.success?, err
    assert_includes out, "Scout Run Control"
    assert_includes out, "max_scouts=2 active=0 launch_slots=2"
    assert_includes out, "pending=3 launched=0 completed=0 blocked=0"
    assert_includes out, "launchable:"
    assert_includes out, "scout-task-pr123 task-pr123 parallel_scout"
    assert_includes out, "scout-task-ready222 task-ready222 parallel_scout"
  ensure
    FileUtils.rm_rf(dir)
  end

  test "marks scout packet run status locally" do
    dir = Rails.root.join("tmp/devops-cycle-scout-runs-mark-test").to_s
    FileUtils.rm_rf(dir)
    devops_cycle("--write-scout-packets", dir)

    out, err, status = devops_cycle(
      "--scout-runs", dir,
      "--mark-scout-status", "scout-task-pr123:launched",
      "--scout-agent", "casey",
      "--max-scouts", "2"
    )

    assert status.success?, err
    assert_includes out, "pending=2 launched=1 completed=0 blocked=0"
    assert_includes out, "scout-task-pr123 launched agent=casey"

    state = JSON.parse(File.read(File.join(dir, "scout-runs.json")))
    assert_equal "launched", state.dig("packets", "scout-task-pr123", "status")
    assert_equal "casey", state.dig("packets", "scout-task-pr123", "agent_slug")

    out, err, status = devops_cycle(
      "--scout-runs", dir,
      "--mark-scout-status", "scout-task-pr123:completed",
      "--scout-agent", "casey"
    )

    assert status.success?, err
    assert_includes out, "pending=2 launched=0 completed=1 blocked=0"
    assert_includes out, "scout-task-pr123 completed agent=casey"
  ensure
    FileUtils.rm_rf(dir)
  end

  test "prints scout coverage gaps from recorded reports" do
    dir = Rails.root.join("tmp/devops-cycle-scout-coverage-test").to_s
    FileUtils.rm_rf(dir)
    devops_cycle("--write-scout-packets", dir)

    out, err, status = devops_cycle("--scout-coverage", dir)

    assert status.success?, err
    assert_includes out, "Scout Coverage"
    assert_includes out, "packets=3 covered=2 missing=1 conflicts=0"
    assert_includes out, "task-pr123 merge-ready reports=1 outcomes=merge-ready:1"
    assert_includes out, "task-ready222 merge-ready reports=1 outcomes=merge-ready:1"
    assert_includes out, "task-engine789 missing-report reports=0 outcomes=none"
  ensure
    FileUtils.rm_rf(dir)
  end

  test "prints scout report summaries when requested" do
    out, err, status = devops_cycle("--scout-reports")

    assert status.success?, err
    assert_includes out, "Scout Reports (2)"
    assert_includes out, "task-pr123 Ship sidebar recovery"
    assert_includes out, "merge-ready by casey: Diff matches the task and CI is green."
    assert_includes out, "task-ready222 Ship focused DevOps helper"
    assert_includes out, "merge-ready by drew: Helper is scoped and checks are green."
    assert_includes out, "finding: PR body matches the task acceptance criteria"
    assert_includes out, "check: Confirmed qa-intake avi-ready"
  end

  test "includes scout report summaries in JSON when requested" do
    out, err, status = devops_cycle("--json", "--scout-reports")

    assert status.success?, err
    snapshot = JSON.parse(out)
    assert_equal 2, snapshot.dig("summary", "scout_reports")
    task = snapshot.fetch("tasks").find { |item| item.fetch("slug") == "task-pr123" }
    report = task.fetch("scout_reports").first
    assert_equal "merge-ready", report.fetch("outcome")
    assert_equal "casey", report.fetch("agent_slug")
    assert_includes report.fetch("findings"), "No overlapping worktree risk found"
  end

  test "prints conductor decision summary from qa-intake and scout reports" do
    out, err, status = devops_cycle("--decisions")

    assert status.success?, err
    assert_includes out, "Conductor Decisions (4)"
    assert_includes out, "Request Changes (2)"
    assert_includes out, "task-pr123 Ship sidebar recovery"
    assert_includes out, "reason=unresolved task feedback is qa_feedback"
    assert_includes out, "task-block000 Fix stale worktree handoff"
    assert_includes out, "reason=qa-intake status needs-agent"
    assert_includes out, "Wait For CI (0)"
    assert_includes out, "Conductor Review (1)"
    assert_includes out, "task-engine789 Ship shared engine table headers"
    assert_includes out, "Merge Ready (1)"
    assert_includes out, "task-ready222 Ship focused DevOps helper"
    assert_includes out, "scout-reports=merge-ready:1"
  end

  test "includes conductor decisions in JSON when requested" do
    out, err, status = devops_cycle("--json", "--decisions")

    assert status.success?, err
    snapshot = JSON.parse(out)
    decisions = snapshot.fetch("decisions")
    assert_equal 4, decisions.size

    ready = decisions.find { |decision| decision.fetch("slug") == "task-ready222" }
    assert_equal "merge-ready", ready.fetch("recommendation")
    assert_equal({ "merge-ready" => 1, "wait-for-ci" => 0, "request-changes" => 0, "conductor-review" => 0 }, ready.fetch("scout_report_counts"))

    blocked = decisions.find { |decision| decision.fetch("slug") == "task-pr123" }
    assert_equal "request-changes", blocked.fetch("recommendation")
    assert_includes blocked.fetch("reasons"), "unresolved task feedback is qa_feedback"
  end

  test "conductor decisions preserve unresolved feedback after later handoff" do
    data = JSON.parse(File.read(@fixture))
    data.fetch("activities") << {
      "task_slug" => "task-pr123",
      "agent_slug" => "casey",
      "activity_type" => "handoff",
      "description" => "Acknowledged the feedback and checking the fixture.",
      "created_at" => "2026-06-18T14:06:00Z"
    }

    with_fixture(data) do
      out, err, status = devops_cycle("--json", "--decisions")

      assert status.success?, err
      blocked = JSON.parse(out).fetch("decisions").find { |decision| decision.fetch("slug") == "task-pr123" }
      assert_equal "request-changes", blocked.fetch("recommendation")
      assert_equal "handoff", blocked.dig("latest_activity", "activity_type")
      assert_equal "qa_feedback", blocked.dig("unresolved_feedback", "activity_type")
      assert_includes blocked.fetch("reasons"), "unresolved task feedback is qa_feedback"
    end
  end

  test "prints conductor readiness groups" do
    out, err, status = devops_cycle("--readiness")

    assert status.success?, err
    assert_includes out, "Conductor Readiness"
    assert_includes out, "Ready To Merge (1)"
    assert_includes out, "task-ready222 Ship focused DevOps helper"
    assert_includes out, "Needs Conductor Review (1)"
    assert_includes out, "task-engine789 Ship shared engine table headers"
    assert_includes out, "Needs Changes (2)"
    assert_includes out, "task-pr123 Ship sidebar recovery"
    assert_includes out, "task-block000 Fix stale worktree handoff"
    assert_includes out, "Ready To Assemble (1)"
    assert_includes out, "task-qa456 QA contest entry flow"
    assert_includes out, "Assembled Release (1)"
    assert_includes out, "task-prod999 Release accepted QA work"
  end

  test "readiness includes scout coverage gaps when coverage is provided" do
    dir = Rails.root.join("tmp/devops-cycle-readiness-coverage-test").to_s
    FileUtils.rm_rf(dir)
    devops_cycle("--write-scout-packets", dir)

    out, err, status = devops_cycle("--scout-coverage", dir, "--readiness")

    assert status.success?, err
    assert_includes out, "Scout Gaps (1)"
    assert_includes out, "task-engine789 Ship shared engine table headers"
    assert_includes out, "recommendation=missing-report"
    assert_includes out, "reason=scout packet has no matching recorded scout report"
  ensure
    FileUtils.rm_rf(dir)
  end

  test "prints scout report dry-run payload without live credentials" do
    out, err, status = devops_cycle(
      "--record-scout-report", "task-pr123",
      "--outcome", "merge-ready",
      "--summary", "No blockers found.",
      "--finding", "Diff matches the PR body.",
      "--question", "Should this deploy with the release slug?",
      "--check", "Reviewed changed files.",
      "--scout-agent", "casey",
      "--dry-run",
      "--json"
    )

    assert status.success?, err
    payload = JSON.parse(out)
    activity = payload.fetch("activity")
    assert_equal true, payload.fetch("dry_run")
    assert_equal "task-pr123", activity.fetch("task_slug")
    assert_equal "comment", activity.fetch("activity_type")
    assert_equal "casey", activity.fetch("agent_slug")
    assert_equal "scout_report", activity.dig("metadata", "kind")
    assert_equal "merge-ready", activity.dig("metadata", "outcome")
    assert_includes activity.dig("metadata", "findings"), "Diff matches the PR body."
    assert_includes activity.fetch("description"), "Scout report: merge-ready - No blockers found."
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

  def with_fixture(data)
    original = @fixture
    Tempfile.create(["devops-cycle", ".json"]) do |file|
      file.write(JSON.pretty_generate(data))
      file.close
      @fixture = file.path
      yield
    end
  ensure
    @fixture = original
  end
end
