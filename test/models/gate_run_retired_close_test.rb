# frozen_string_literal: true

require "test_helper"
require "rake"

# The one-time close of stale g1_cert attempts (remove-dead-local-check-indicator).
# The local cert is retired, so an attempt still in flight is one a killed cert left
# open; the release's post_deploy_cmd closes them, and must be safe to run twice.
class GateRunRetiredCloseTest < ActiveSupport::TestCase
  setup do
    @task = tasks(:new_task)
    @stale = GateRun.create!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert",
                             attempt: 1, started_at: 3.days.ago)
    @settled = GateRun.create!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert",
                               attempt: 2, started_at: 2.days.ago, finished_at: 2.days.ago, success: true)
    @live = GateRun.create!(subject_type: "task", subject_slug: @task.slug, key: "dor",
                            attempt: 1, started_at: 1.minute.ago)
  end

  test "[unit] closes only in-flight retired rows, with no verdict, and is idempotent" do
    settled_at = @settled.reload.finished_at
    freeze_time do
      assert_equal 1, GateRun.close_retired_in_flight!

      @stale.reload
      assert_equal Time.current, @stale.finished_at
      assert_nil @stale.success, "an abandoned run has no verdict; the grader must not count it a failure"
      assert_match(/retired gate/, @stale.metadata["closed_reason"])
      assert @live.reload.in_flight?, "a live gate is not touched"
      assert_equal settled_at, @settled.reload.finished_at, "a settled retired row keeps its close"
      assert @settled.success

      assert_equal 0, GateRun.close_retired_in_flight!, "a second run finds nothing to close"
    end
  end

  test "[unit] the post_deploy rake task closes them and exits zero when none are left" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("gate_runs:close_retired")
    task = Rake::Task["gate_runs:close_retired"]
    task.reenable

    out, = capture_io { task.invoke }

    assert_match(/closed 1 in-flight retired gate run\(s\); 0 still open/, out)
    assert_not @stale.reload.in_flight?
  ensure
    task&.reenable
  end
end
