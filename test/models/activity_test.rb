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

  test "requires a type and description" do
    activity = Activity.new(task_slug: tasks(:new_task).slug)

    assert_not activity.valid?
    assert_includes activity.errors[:activity_type], "can't be blank"
    assert_includes activity.errors[:description], "can't be blank"
  end
end
