require "test_helper"

# The enqueue TRIGGER: a task entering `designed` without a po_size fires
# AviSizingJob (async, non-blocking) — the parallel-sizing half of the feature.
class TaskAviSizingTriggerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "creating a designed task without po_size enqueues AviSizingJob with its slug" do
    task = nil
    assert_enqueued_jobs 1, only: AviSizingJob do
      task = Task.create!(title: "Trigger sizes this")
    end
    assert_equal "designed", task.stage
    assert_enqueued_with(job: AviSizingJob, args: [task.slug])
  end

  test "does not enqueue when po_size is already set at creation" do
    assert_no_enqueued_jobs only: AviSizingJob do
      Task.create!(title: "Presized on create here", po_size: "medium")
    end
  end

  test "does not enqueue when the task is created in a non-designed stage" do
    assert_no_enqueued_jobs only: AviSizingJob do
      Task.create!(title: "Born already building", stage: "building")
    end
  end

  test "enqueues on a move INTO designed while still unsized" do
    task = Task.create!(title: "Bounced back to designed", stage: "building")
    clear_enqueued_jobs
    assert_enqueued_jobs 1, only: AviSizingJob do
      task.update!(stage: "designed")
    end
  end

  test "does not re-enqueue on a non-stage edit of a designed unsized task" do
    task = nil
    assert_enqueued_jobs 1, only: AviSizingJob do
      task = Task.create!(title: "Designed then edited")
    end
    clear_enqueued_jobs
    assert_no_enqueued_jobs only: AviSizingJob do
      task.update!(description: "just a note, no stage change")
    end
  end
end
