# frozen_string_literal: true

require "test_helper"

# The retry CHAIN — the half of the trigger the webhook cannot cover. CI that
# settles green BEFORE the reviewer arms delivers no further webhook, a delivery
# can be dropped, and a lapsing review lease is a moment nothing announces. The
# chain is what makes those cases finish anyway; it must keep itself alive while
# an action can still succeed, and it must stop the moment it cannot.
class ReviewPendingActionExecutionJobTest < ActiveJob::TestCase
  SLUG = "chain-subject"

  def setup
    @task = Task.create!(title: "Chain Subject Task", slug: SLUG, stage: "submitted",
                         metadata: { "devops" => { "repositories" => ["mcritchie-studio"],
                                                   "branch" => "feat/chain-subject",
                                                   "pr_url" => "https://github.com/x/y/pull/5" } })
    Activity.create!(task_slug: SLUG, agent_slug: "carl", activity_type: "comment",
                     description: "Scout report: merge-ready",
                     metadata: { "kind" => "scout_report", "outcome" => "merge-ready" })
    @action = ReviewPendingAction.arm!(task: @task, repo: "McRitchie-Studio/mcritchie-studio",
                                       pr_number: 5, head_sha: "c" * 40, authorized_by: "carl")
  end

  test "a WAITING recheck reschedules itself so a missed webhook still lands" do
    assert_enqueued_with(job: ReviewPendingActionExecutionJob) do
      ReviewPendingActionExecutionJob.perform_now(@action.id, recheck: true)
    end
    assert_equal ReviewPendingAction::PENDING, @action.reload.state
  end

  # Otherwise every at-least-once webhook delivery would fork another chain, and
  # the rechecks would multiply instead of repeating.
  test "the WEBHOOK path is one-shot and starts no chain of its own" do
    assert_no_enqueued_jobs(only: ReviewPendingActionExecutionJob) do
      ReviewPendingActionExecutionJob.perform_now(@action.id)
    end
  end

  test "the chain stops once the action is settled" do
    @action.settle!(state: ReviewPendingAction::DISARMED, reason: "withdrawn")

    assert_no_enqueued_jobs(only: ReviewPendingActionExecutionJob) do
      ReviewPendingActionExecutionJob.perform_now(@action.id, recheck: true)
    end
  end

  # The chain is bounded by the action's own clock — this is what stops a merge
  # order looping for ever against a world that has moved on.
  test "the chain ends by EXPIRING the action rather than rescheduling for ever" do
    @action.update!(expires_at: 1.minute.ago)

    assert_no_enqueued_jobs(only: ReviewPendingActionExecutionJob) do
      ReviewPendingActionExecutionJob.perform_now(@action.id, recheck: true)
    end
    assert_equal ReviewPendingAction::EXPIRED, @action.reload.state
  end

  test "a deleted action is a no-op, not a crash" do
    id = @action.id
    @action.destroy!
    assert_nothing_raised { ReviewPendingActionExecutionJob.perform_now(id, recheck: true) }
  end
end
