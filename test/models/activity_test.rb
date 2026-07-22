require "test_helper"

class ActivityTest < ActiveSupport::TestCase
  test "belongs to a task by slug" do
    task = tasks(:new_task)
    activity = Activity.create!(
      task_slug: task.slug,
      activity_type: "qa_feedback",
      description: "Rebase before QA review."
    )

    assert_equal task, activity.task
    assert_equal [activity], Activity.for_task(task).to_a
    assert_equal "QA Feedback", activity.activity_type_label
    assert activity.task_conversation?
  end

  test "[unit] classifies clarifications separately from blocking qa feedback" do
    clarification = Activity.new(activity_type: "clarification", description: "Can you confirm the release target?")
    blocker = Activity.new(activity_type: "qa_feedback", description: "Fix the failing system test before merge.")

    assert_includes Activity::TASK_CONVERSATION_TYPES, "clarification"
    assert_equal "Clarification", clarification.activity_type_label
    assert_equal "Non-blocking question or answer", clarification.activity_type_description
    assert clarification.clarification?
    assert_not clarification.blocking_feedback?
    assert blocker.blocking_feedback?
  end

  test "requires a type and description" do
    activity = Activity.new(task_slug: tasks(:new_task).slug)

    assert_not activity.valid?
    assert_includes activity.errors[:activity_type], "can't be blank"
    assert_includes activity.errors[:description], "can't be blank"
  end

  test "only explicit handoff metadata resolves feedback" do
    handoff = Activity.new(activity_type: "handoff", description: "Addressed.", metadata: { "resolves_feedback" => "true" })
    comment = Activity.new(activity_type: "comment", description: "Addressed.", metadata: { "resolves_feedback" => "true" })

    assert handoff.resolves_feedback?
    refute comment.resolves_feedback?
  end

  test "[unit] block_summary reads the stored 4-6 word summary from metadata" do
    activity = Activity.new(
      activity_type: "qa_feedback",
      description: "The stage transition bypasses the server guard entirely, so a client can force it.",
      metadata: { "summary" => "Stage move skips server guard" }
    )

    assert_equal "Stage move skips server guard", activity.block_summary
  end

  test "[unit] block_summary derives a truncated headline for a legacy blocker with no summary" do
    activity = Activity.new(
      activity_type: "qa_feedback",
      description: "The stage transition bypasses the server guard entirely and must be re-gated.\nSee the diff."
    )

    # First line, first six words, ellipsis — legacy blockers still render clean.
    assert_equal "The stage transition bypasses the server…", activity.block_summary
  end

  test "[unit] block_summary of a short legacy blocker is the details verbatim" do
    activity = Activity.new(activity_type: "qa_feedback", description: "Rebase before QA.")

    assert_equal "Rebase before QA.", activity.block_summary
  end

  test "[unit] block_summary ignores a blank stored summary and falls back to derivation" do
    activity = Activity.new(
      activity_type: "qa_feedback",
      description: "Fix the failing system test before merge.",
      metadata: { "summary" => "   " }
    )

    assert_equal "Fix the failing system test before…", activity.block_summary
  end
end
