require "test_helper"

# The retention job against a realistic backlog. The first production run clears ~100k
# rows from a table every agent writes to constantly, so what matters here is SHAPE:
# many small DELETE statements rather than one big one, a pause between them, a budget
# that stops a run cleanly and lets the next one resume, and the durable readers of old
# rows (a task's CI phase, a banked insight) reading the same thing after a run as before.
class AgentActionRetentionBatchingTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 9, 17, 12, 0, 0)

  def seed_actions(count, occurred_at:, session_id: "retention-backlog")
    rows = Array.new(count) do |i|
      { session_id: session_id, kind: "bash", seq: i, occurred_at: occurred_at - i.seconds,
        created_at: occurred_at, updated_at: occurred_at }
    end
    AgentAction.insert_all!(rows)
  end

  def delete_statements
    statements = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      statements << sql if sql.start_with?("DELETE FROM \"agent_actions\"")
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  test "[integration] a backlog is cleared in small batches, with a pause between them" do
    travel_to(NOW) do
      seed_actions(1_250, occurred_at: 50.days.ago)
      seed_actions(300, occurred_at: 44.days.ago, session_id: "retention-window")

      job = AgentActionRetentionJob.new
      pauses = []
      result = nil
      statements = delete_statements do
        job.stub(:sleep, ->(seconds) { pauses << seconds }) do
          result = job.perform(batch_size: 100, pause: 0.25)
        end
      end

      assert_equal 1_250, result.deleted
      assert_equal 13, result.batches, "12 full batches of 100, then a short batch of 50 that drains"
      assert result.drained
      assert_equal 0, result.retained
      assert_equal 13, statements.size, "one DELETE statement per batch, never one statement for the backlog"
      assert(statements.all? { |sql| sql.include?("LIMIT") }, "every DELETE is bounded by a LIMIT")
      assert_equal [0.25] * 12, pauses, "a pause after every full batch, none after the drain"

      assert_equal 0, AgentAction.where(session_id: "retention-backlog").count
      assert_equal 300, AgentAction.where(session_id: "retention-window").count,
                   "rows inside the 45-day window are never touched"
    end
  end

  test "[integration] a run that hits its budget stops cleanly and the next run resumes" do
    travel_to(NOW) do
      seed_actions(250, occurred_at: 60.days.ago)

      first = AgentActionRetentionJob.perform_now(batch_size: 100, max_runtime: 0, pause: 0)

      assert_equal 100, first.deleted, "a spent budget stops after the batch in hand"
      assert_not first.drained
      assert_nil first.retained
      assert_equal 150, AgentAction.count

      second = AgentActionRetentionJob.perform_now(batch_size: 100, pause: 0)

      assert_equal 150, second.deleted
      assert second.drained
      assert_equal 0, AgentAction.count
    end
  end

  test "[integration] a task's CI phase and a banked insight read the same after a run" do
    travel_to(NOW) do
      anchor = 90.days.ago
      task = Task.create!(title: "Retention Phase Probe")
      [["building", 0], ["submitted", 20], ["reviewed", 40]].each do |stage, minutes|
        task.task_events.create!(kind: "transition", from_stage: task.stage, to_stage: stage,
                                 occurred_at: anchor + minutes.minutes, seconds_in_from: nil,
                                 source: "test", metadata: {})
      end
      %w[ci_rails ci_test].each_with_index do |slug, i|
        AgentAction.create!(session_id: "retention-ci", kind: "test_scope", event_slug: slug,
                            result_slug: "pass", task_slug: task.slug, occurred_at: anchor + (25 + i).minutes,
                            duration_ms: 60_000)
      end

      graded = AgentAction.create!(session_id: "retention-graded", kind: "edit", task_slug: task.slug,
                                   occurred_at: anchor)
      ActionGrade.create!(agent_action: graded, grader: ActionGrade::ALEX, slug: "a lesson worth keeping",
                          disposition: ActionGrade::GOOD).bank!

      activity = AgentActivity.create!(session_id: "retention-backlog", category: "Edit",
                                       reason_slug: "old work", opened_at: anchor, seq: 0)
      seed_actions(40, occurred_at: anchor)
      AgentAction.where(session_id: "retention-backlog").update_all(agent_activity_id: activity.id)

      ci_before = Task::TestingPhases.build(task)["phases"]["ci"]
      insight_before = ActionGrade.insight_feed.map(&:to_insight)

      result = AgentActionRetentionJob.perform_now(batch_size: 10, pause: 0)

      assert_equal 40, result.deleted, "only the ordinary telemetry goes"
      assert_equal 3, result.retained, "two CI-scope rows and one graded row are kept"

      ci_after = Task::TestingPhases.refresh!(task.reload)["phases"]["ci"]
      assert_equal "completed", ci_before["status"], "the probe must start with a measured CI phase"
      assert_equal ci_before.except("cached_at"), ci_after.except("cached_at"),
                   "rebuilding the CI phase after a run must not blank it"

      assert_equal insight_before, ActionGrade.insight_feed.map(&:to_insight)
      assert_equal task.slug, ActionGrade.insight_feed.first.to_insight["task_slug"],
                   "the banked insight still names the task it was learned on"

      assert AgentActivity.exists?(activity.id), "narrated activities are out of scope and stay"
    end
  end
end
