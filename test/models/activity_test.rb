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
end
