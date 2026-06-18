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
    assert_includes out, "PR Review (1)"
    assert_includes out, "QA Review (1)"
    assert_includes out, "Ship sidebar recovery (task-pr123)"
    assert_includes out, "https://www.mcritchie.studio/tasks/task-pr123"
    assert_includes out, "qa-intake: avi-ready amcritchie/mcritchie-studio#123"
    assert_includes out, "latest qa_feedback: Needs one more navbar regression test before merge."
  end

  test "prints machine-readable enriched task JSON" do
    out, err, status = devops_cycle("--json")

    assert status.success?, err
    snapshot = JSON.parse(out)
    assert_equal 2, snapshot.dig("summary", "tasks")
    task = snapshot.fetch("tasks").find { |item| item.fetch("slug") == "task-qa456" }
    assert_equal "https://qa.turfmonster.media/contests/test", task.dig("devops", "qa_url")
    assert_equal "checks-review", task.dig("qa_intake", "status")
    assert_equal "handoff", task.dig("latest_activity", "activity_type")
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
