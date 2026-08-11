# frozen_string_literal: true

require "test_helper"

# Unit coverage for the ARMED MERGE record itself — the authorisation gate on
# creation, the trigger key the CI webhook JOINs on, and the expiry clock. The
# execution guards live in test/services/review/pending_action_executor_test.rb.
class ReviewPendingActionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  SLUG = "armed-merge-subject"
  REPO = "McRitchie-Studio/mcritchie-studio"
  SHA  = "abc123def456abc123def456abc123def456abcd"

  def setup
    @task = Task.create!(title: "Armed Merge Subject", slug: SLUG, stage: "submitted")
  end

  def record_verdict(outcome: "merge-ready", agent: "carl")
    Activity.create!(task_slug: SLUG, agent_slug: agent, activity_type: "comment",
                     description: "Scout report: #{outcome}",
                     metadata: { "kind" => "scout_report", "outcome" => outcome })
  end

  def arm(head_sha: SHA, repo: REPO, **kwargs)
    ReviewPendingAction.arm!(task: @task.reload, repo: repo, pr_number: 77, head_sha: head_sha, **kwargs)
  end

  test "arming records the authorising verdict, its author, and the pin" do
    verdict = record_verdict
    action = arm

    assert_equal SLUG, action.task_slug
    assert_equal ReviewPendingAction::MERGE_TO_ACCEPTED, action.action
    assert_equal ReviewPendingAction::AUTHORISING_VERDICT, action.verdict
    assert_equal verdict.id, action.verdict_activity_id
    assert_equal "carl", action.authorized_by, "the verdict's author authorises the merge"
    assert_equal SHA, action.head_sha
    assert_equal "accepted", action.base_branch
    assert action.pending?
  end

  test "arming is refused with no recorded merge-ready verdict" do
    assert_raises(ReviewPendingAction::Unauthorised) { arm }
    assert_equal 0, ReviewPendingAction.count
  end

  test "the newest merge-ready verdict authorises, even behind a later comment" do
    record_verdict
    newest = record_verdict
    Activity.create!(task_slug: SLUG, activity_type: "comment", description: "a plain note")

    assert_equal newest.id, arm.verdict_activity_id
  end

  test "a verdict recorded on ANOTHER task never authorises this one" do
    other = Task.create!(title: "Some Other Task", slug: "some-other-task", stage: "submitted")
    Activity.create!(task_slug: other.slug, activity_type: "comment", description: "Scout report",
                     metadata: { "kind" => "scout_report", "outcome" => "merge-ready" })

    assert_raises(ReviewPendingAction::Unauthorised) { arm }
  end

  # The trigger JOINs on repo + head_sha. An action armed with a bare repo slug or
  # an uppercased sha would never be found by its own trigger — invisible rather
  # than refused, which is the worst failure mode available.
  test "normalises the trigger key so the webhook can always find it" do
    record_verdict
    action = arm(repo: "mcritchie-studio", head_sha: SHA.upcase)

    assert_equal REPO, action.repo
    assert_equal SHA, action.head_sha
  end

  test "trigger_for_head enqueues exactly the actions pinned to that tree" do
    record_verdict
    action = arm

    assert_enqueued_with(job: ReviewPendingActionExecutionJob, args: [action.id]) do
      assert_equal 1, ReviewPendingAction.trigger_for_head(repo: REPO, head_sha: SHA)
    end
  end

  test "trigger_for_head ignores another tree, another repo, and settled actions" do
    record_verdict
    action = arm

    assert_no_enqueued_jobs(only: ReviewPendingActionExecutionJob) do
      assert_equal 0, ReviewPendingAction.trigger_for_head(repo: REPO, head_sha: "f" * 40)
      assert_equal 0, ReviewPendingAction.trigger_for_head(repo: "McRitchie-Studio/turf-monster", head_sha: SHA)
      assert_equal 0, ReviewPendingAction.trigger_for_head(repo: REPO, head_sha: "")
    end

    action.settle!(state: ReviewPendingAction::EXECUTED, reason: "done")
    assert_no_enqueued_jobs(only: ReviewPendingActionExecutionJob) do
      assert_equal 0, ReviewPendingAction.trigger_for_head(repo: REPO, head_sha: SHA)
    end
  end

  test "expiry is a closed window — expired at the boundary, live one second before" do
    record_verdict
    action = arm(ttl: 1.hour)

    refute action.expired?(now: action.expires_at - 1.second)
    assert action.expired?(now: action.expires_at)
    assert action.expired?(now: action.expires_at + 1.second)
  end

  test "at most one live action per task survives a re-arm" do
    record_verdict
    first = arm(head_sha: SHA)
    second = arm(head_sha: "b" * 40)

    assert_equal ReviewPendingAction::DISARMED, first.reload.state
    assert_match(/superseded/, first.outcome_reason)
    assert_equal 1, ReviewPendingAction.pending.where(task_slug: SLUG).count
    assert_equal second.id, ReviewPendingAction.pending.find_by(task_slug: SLUG).id
  end

  test "verdict_recorded? follows the activity, not a copy of it" do
    verdict = record_verdict
    action = arm

    assert action.verdict_recorded?
    verdict.destroy!
    assert_not action.verdict_recorded?, "a withdrawn decision must stop authorising"
  end

  # ── ARMING FOLLOWS THE LATEST VERDICT ───────────────────────────────────────
  # The rule is "the task's CURRENT decision is merge-ready", NOT "a merge-ready
  # report exists somewhere in the history". Reading past a revision to find an
  # outcome we like is the "never invent a verdict" rule broken from the far end.

  ["request-changes", "wait-for-ci", "conductor-review"].each do |outcome|
    test "arming is refused when a later #{outcome} report has revised the decision" do
      record_verdict
      record_verdict(outcome: outcome, agent: "avi")

      error = assert_raises(ReviewPendingAction::Unauthorised) { arm }
      assert_match(/latest scout report/, error.message)
      assert_match(/#{outcome}/, error.message)
      assert_equal 0, ReviewPendingAction.count, "a revised decision must arm nothing at all"
    end
  end

  # The guard must not be over-broad. Two reviewers each record their own scout
  # report on one PR; the light reviewer agreeing AFTER the primary is a
  # re-affirmation, not a revision, and refusing it would break the normal path.
  test "a later merge-ready report re-affirms rather than revises — arming still works" do
    record_verdict
    newest = record_verdict(agent: "avi")

    action = arm
    assert_equal newest.id, action.verdict_activity_id
    assert_equal "avi", action.authorized_by
  end

  test "the refusal names the report that is actually standing" do
    record_verdict
    record_verdict(outcome: "request-changes", agent: "avi")

    error = assert_raises(ReviewPendingAction::Unauthorised) { arm }
    assert_match(/avi/, error.message, "an operator must learn WHOSE revision is in the way")
  end

  # ── THE DESTINATION IS THE ACTION TYPE'S, NOT THE CALLER'S ──────────────────
  # `MERGE_TO_ACCEPTED` names its destination; before this the column was
  # free-form, so the name was a label on data that could say anything. The whole
  # argument for merging unattended is that the blast radius is `accepted`.

  test "arming refuses a destination this action type may not merge into" do
    record_verdict

    error = assert_raises(ReviewPendingAction::Unauthorised) { arm(base_branch: "main") }
    assert_match(/may only merge into accepted/, error.message)
    assert_equal 0, ReviewPendingAction.count
  end

  test "arming with no base branch defaults to the action type's own destination" do
    record_verdict
    assert_equal "accepted", arm(base_branch: nil).base_branch
  end

  # The structural floor: arm! is the ONE creation path today, but the validation
  # is what makes that true tomorrow — a console create! or a second caller cannot
  # record a merge order pointing somewhere this action may not go.
  test "the validation refuses a wrong destination on any writer, not just arm!" do
    record_verdict
    action = arm

    action.base_branch = "main"
    assert_not action.valid?
    assert_match(/may only target accepted/, action.errors.full_messages.join(" "))

    assert_raises(ActiveRecord::RecordInvalid) do
      ReviewPendingAction.create!(
        task_slug: SLUG, action: ReviewPendingAction::MERGE_TO_ACCEPTED, repo: REPO,
        pr_number: 78, head_sha: "c" * 40, verdict: ReviewPendingAction::AUTHORISING_VERDICT,
        base_branch: "main", state: ReviewPendingAction::PENDING, expires_at: 1.hour.from_now
      )
    end
  end

  # ── superseding_scout_report ────────────────────────────────────────────────

  test "superseding_scout_report names a revision and stays quiet otherwise" do
    record_verdict
    action = arm
    assert_nil action.superseding_scout_report, "an unrevised decision is not superseded"

    record_verdict(agent: "avi")
    assert_nil action.superseding_scout_report, "a second merge-ready is a re-affirmation"

    revision = record_verdict(outcome: "request-changes", agent: "avi")
    assert_equal revision.id, action.superseding_scout_report&.id
  end
end
