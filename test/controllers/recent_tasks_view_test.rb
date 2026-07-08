require "test_helper"

# /tasks/recent — the flat recency list showcasing per-task testing-phase
# durations + gate verdict chips. Public-read; the kanban board is untouched.
class RecentTasksViewTest < ActionDispatch::IntegrationTest
  setup do
    @new_task = tasks(:new_task)
    @in_progress_task = tasks(:in_progress_task)
  end

  test "[component] recent lists tasks newest-updated first with compact phase duration cells" do
    @new_task.update_columns(updated_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations
    @in_progress_task.update_columns( # rubocop:disable Rails/SkipsModelValidations
      updated_at: 2.hours.ago,
      testing_phases_version: Task::TestingPhases::VERSION,
      testing_phases: { "phases" => {
        "build" => { "status" => "completed", "seconds" => 7440 },
        "local_certification" => { "status" => "in_progress", "seconds" => 300 },
        "ci" => { "status" => "missing" },
        "review" => { "status" => "missing" },
        "acceptance" => { "status" => "missing" }
      } }
    )

    get recent_tasks_path

    assert_response :success
    assert_select "h1", "Recent Tasks"
    assert_select "li[data-test=?]", "recent-task-row", minimum: 2

    newer = response.body.index("data-task-slug=\"#{@new_task.slug}\"")
    older = response.body.index("data-task-slug=\"#{@in_progress_task.slug}\"")
    assert newer && older, "both controlled tasks render rows"
    assert newer < older, "the more recently updated task renders first"

    assert_includes response.body, "2h 4m",
                    "a completed phase renders the compact two-unit duration"
    assert_includes response.body, "5m+",
                    "an in-progress phase ticks with a trailing plus"
  end

  test "[component] recent renders gate verdict chips including the failed-then-passed retry story" do
    GateRun.close!(subject_type: "task", subject_slug: @new_task.slug, key: "g1_cert", success: false)
    GateRun.close!(subject_type: "task", subject_slug: @new_task.slug, key: "g1_cert", success: true)
    GateRun.open!(subject_type: "task", subject_slug: @new_task.slug, key: "g2a_primary")

    get recent_tasks_path

    assert_response :success
    assert_select "li[data-task-slug=?]", @new_task.slug do
      assert_select "[data-test=?]", "recent-gate-chip", count: 2
    end
    assert_includes response.body, "attempt 2",
                    "the failed first attempt stays visible as a retry count"
    assert_includes response.body, "G1 Cert"
    assert_includes response.body, "G2a Primary"
  end

  test "[component] a task with no phases and no gate runs reads as a clean sparse row" do
    get recent_tasks_path

    assert_response :success
    assert_select "li[data-task-slug=?]", @new_task.slug do
      assert_select "[data-test=?]", "recent-task-phases", count: 1
      assert_select "[data-test=?]", "recent-gate-chip", count: 0
    end
    assert_includes response.body, "—", "never-run phases render dashes, not blanks"
  end

  test "[component] recent excludes archived tasks" do
    @new_task.update_columns(stage: "archived") # rubocop:disable Rails/SkipsModelValidations

    get recent_tasks_path

    assert_response :success
    assert_select "li[data-task-slug=?]", @new_task.slug, count: 0
  end
end
