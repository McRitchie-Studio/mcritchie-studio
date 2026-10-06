# frozen_string_literal: true

require "test_helper"
require "rake"

# TaskDevopsColumnsBackfillJob copies each devops key into its column for rows
# saved before the columns existed, and for rows old code wrote during a deploy.
class TaskDevopsColumnsBackfillJobTest < ActiveJob::TestCase
  PR_URL = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/5150"
  KEYS = { "pr_url" => PR_URL, "branch" => "feat/backfill", "approval_status" => "approved",
           "session_id" => "sess-backfill" }.freeze

  # A row as the pre-column code left it: keys in metadata, columns NULL.
  def legacy_task(devops = KEYS)
    t = Task.create!(title: "backfill sample legacy task", stage: "building",
                     metadata: { "devops" => { "shape" => "backend" } })
    t.update_columns(metadata: { "devops" => { "shape" => "backend" }.merge(devops)}, # rubocop:disable Rails/SkipsModelValidations
                     **Task::DEVOPS_MIRRORED_KEYS.index_with(nil).symbolize_keys)
    t
  end

  def columns(record)
    Task::DEVOPS_MIRRORED_KEYS.index_with { |key| record.reload.read_attribute(key) }
  end

  test "[unit] copies every mirrored key for every task" do
    first = legacy_task
    second = legacy_task(KEYS.merge("pr_url" => PR_URL.sub("5150", "5151"), "session_id" => "sess-2"))

    result = TaskDevopsColumnsBackfillJob.perform_now

    assert_equal KEYS, columns(first)
    assert_equal KEYS.merge("pr_url" => PR_URL.sub("5150", "5151"), "session_id" => "sess-2"), columns(second)
    assert_operator result.updated, :>=, 2
    assert_equal 0, result.divergent
  end

  test "[unit] a second run updates nothing" do
    legacy_task
    TaskDevopsColumnsBackfillJob.perform_now

    assert_equal 0, TaskDevopsColumnsBackfillJob.perform_now.updated
  end

  test "[unit] the key wins over a stale column and a blank key clears it" do
    t = legacy_task(KEYS.merge("branch" => "  ", "approval_status" => "none"))
    t.update_columns(branch: "feat/stale", approval_status: "waiting") # rubocop:disable Rails/SkipsModelValidations

    TaskDevopsColumnsBackfillJob.perform_now

    assert_nil columns(t)["branch"]
    assert_equal "none", columns(t)["approval_status"]
  end

  test "[unit] it touches no updated_at" do
    t = legacy_task
    stamp = t.reload.updated_at

    TaskDevopsColumnsBackfillJob.perform_now

    assert_equal stamp, t.reload.updated_at
  end

  test "[unit] it agrees with the save-time mirror byte for byte" do
    saved = Task.create!(title: "backfill sample saved task", stage: "building",
                         metadata: { "devops" => { "shape" => "backend" }.merge(KEYS) })

    assert_equal 0, TaskDevopsColumnsBackfillJob.divergent.where(id: saved.id).count
  end

  test "[unit] the rake task reports the counts and passes when nothing diverges" do
    legacy_task
    Rails.application.load_tasks unless Rake::Task.task_defined?("tasks:backfill_devops_columns")
    task = Rake::Task["tasks:backfill_devops_columns"]
    task.reenable

    out, = capture_io { task.invoke }

    assert_match(/updated \d+ task\(s\); 0 still diverge/, out)
  end
  # Regression: the rake called perform_now, and ApplicationJob's retry_on
  # StandardError swallowed the failure into a queued retry, so the rake died on
  # a NoMethodError for `updated` instead of the job's own error.
  test "[unit] rake tasks:backfill_devops_columns raises the job's own error" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tasks:backfill_devops_columns")
    task = Rake::Task["tasks:backfill_devops_columns"]
    task.reenable
    boom = Class.new(StandardError)

    Task.stub(:in_batches, ->(*, **) { raise boom, "the job's own failure" }) do
      error = assert_raises(boom) { capture_io { task.invoke } }
      assert_equal "the job's own failure", error.message
    end
    assert_no_enqueued_jobs only: TaskDevopsColumnsBackfillJob
  end
end
