require "test_helper"

# [unit] BlockInsightMiningJob — the async wrapper over Insights::BlockMiner, plus
# the Activity trigger that enqueues it when a handoff resolves a block.
class BlockInsightMiningJobTest < ActiveJob::TestCase
  def resolved_block(task_slug:)
    now = Time.current
    AgentActivity.create!(session_id: "sess-job", category: "Edit", reason_slug: "worked",
                        task_slug: task_slug, opened_at: now - 10.minutes, seq: 0)
    Activity.create!(task_slug: task_slug, activity_type: "qa_feedback",
                     description: "the guard was bypassed", created_at: now - 5.minutes)
    Activity.create!(task_slug: task_slug, activity_type: "handoff", description: "fixed",
                     metadata: { "resolves_feedback" => true }, created_at: now - 1.minute)
  end

  test "[unit] perform mines resolved blocks into candidates" do
    resolved_block(task_slug: "t-job")

    assert_difference -> { ActionGrade.seeded_candidates.count }, 1 do
      BlockInsightMiningJob.perform_now("t-job")
    end
  end

  test "[unit] a resolving handoff enqueues the miner scoped to its task" do
    Activity.create!(task_slug: "t-trigger", activity_type: "qa_feedback", description: "bad")

    assert_enqueued_with(job: BlockInsightMiningJob, args: ["t-trigger"]) do
      Activity.create!(task_slug: "t-trigger", activity_type: "handoff", description: "addressed",
                       metadata: { "resolves_feedback" => true })
    end
  end

  test "[unit] a plain handoff (not resolving feedback) does not enqueue the miner" do
    assert_no_enqueued_jobs only: BlockInsightMiningJob do
      Activity.create!(task_slug: "t-plain", activity_type: "handoff", description: "just a note")
    end
  end

  test "[unit] a bad scan is swallowed into ErrorLog, never re-raised" do
    Insights::BlockMiner.stub(:mine!, ->(*) { raise "scan blew up" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_nothing_raised { BlockInsightMiningJob.perform_now("t-boom") }
      end
    end
    assert_equal "t-boom", ErrorLog.order(:id).last.target_name
  end
end
