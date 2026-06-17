require "test_helper"

class TasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @new_task = tasks(:new_task)
    @queued_task = tasks(:queued_task)
    @in_progress_task = tasks(:in_progress_task)
    @done_task = tasks(:done_task)
    @failed_task = tasks(:failed_task)
  end

  # === HTML page tests ===

  test "index renders tasks page" do
    get tasks_path
    assert_response :success
    assert_select "h2", "Tasks"
  end

  test "show renders task detail" do
    get task_path(@new_task.slug)
    assert_response :success
  end

  # === Kanban stage moves via JSON PATCH ===

  test "move task to any stage via PATCH JSON" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "done" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "done", @new_task.stage
    assert_not_nil @new_task.completed_at
  end

  test "move task backwards via PATCH JSON" do
    log_in_as(@admin)
    patch task_path(@done_task.slug, format: :json),
          params: { task: { stage: "new" } }, as: :json
    assert_response :success
    @done_task.reload
    assert_equal "new", @done_task.stage
  end

  test "move task to queued sets queued_at" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "queued" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "queued", @new_task.stage
    assert_not_nil @new_task.queued_at
  end

  test "move task to in_progress sets started_at" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "in_progress" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "in_progress", @new_task.stage
    assert_not_nil @new_task.started_at
  end

  test "move task through DevOps handoff stages" do
    log_in_as(@admin)

    %w[pr_review qa_review prod_ready].each do |stage|
      patch task_path(@new_task.slug, format: :json),
            params: { task: { stage: stage } }, as: :json
      assert_response :success
      assert_equal stage, @new_task.reload.stage
    end
  end

  test "move task to failed sets failed_at" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "failed" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "failed", @new_task.stage
    assert_not_nil @new_task.failed_at
  end

  test "move task to archived sets archived_at" do
    log_in_as(@admin)
    patch task_path(@done_task.slug, format: :json),
          params: { task: { stage: "archived" } }, as: :json
    assert_response :success
    @done_task.reload
    assert_equal "archived", @done_task.stage
    assert_not_nil @done_task.archived_at
  end

  # === Transition methods still work ===

  test "queue transition works via JSON" do
    log_in_as(@admin)
    post queue_task_path(@new_task.slug, format: :json)
    assert_response :success
    @new_task.reload
    assert_equal "queued", @new_task.stage
  end

  test "complete transition works via JSON" do
    log_in_as(@admin)
    post complete_task_path(@in_progress_task.slug, format: :json)
    assert_response :success
    @in_progress_task.reload
    assert_equal "done", @in_progress_task.stage
  end

  # === Delete ===

  test "delete works via JSON" do
    log_in_as(@admin)
    assert_difference "Task.count", -1 do
      delete task_path(@new_task.slug, format: :json)
    end
    assert_response :no_content
  end

  # === Update fields via JSON ===

  test "update title via JSON returns JSON not redirect" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { title: "Updated Title" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "Updated Title", @new_task.title
  end

  test "create stores devops handoff metadata" do
    log_in_as(@admin)

    assert_difference "Task.count", 1 do
      post tasks_path, params: {
        task: {
          title: "Review Turf PR",
          devops: {
            kind: "feature",
            repositories: "turf-monster, turf-vault",
            branch: "feat/contest-flow",
            pr_url: "https://github.com/amcritchie/turf-monster/pull/149",
            qa_url: "https://qa.turfmonster.media/contests",
            release_train: "2026-06-17-turf",
            requires_release_conductor: "1",
            acceptance: "Contest creates on QA\nEntry submits on QA",
            test_plan: "bin/rails test\nQA devnet mutating smoke"
          }
        }
      }
    end

    task = Task.order(:created_at).last
    assert_redirected_to task_path(task.slug)
    assert task.requires_release_conductor?
    assert_equal ["turf-monster", "turf-vault"], task.devops_repositories
    assert_equal ["Contest creates on QA", "Entry submits on QA"], task.devops_acceptance
    assert_equal "https://qa.turfmonster.media/contests", task.devops_url(:qa)
  end

  test "show renders devops handoff details" do
    @new_task.update!(
      metadata: {
        "devops" => {
          "kind" => "release",
          "repositories" => ["mcritchie-studio"],
          "qa_url" => "https://qa.mcritchie.studio/tasks",
          "acceptance" => ["Task board shows release metadata"]
        }
      }
    )

    get task_path(@new_task.slug)

    assert_response :success
    assert_select ".label-upper", "DevOps handoff"
    assert_select "a[href=?]", "https://qa.mcritchie.studio/tasks"
    assert_includes response.body, "Task board shows release metadata"
  end

  # === Auth enforcement ===

  test "moves require admin" do
    log_in_as(@viewer)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "done" } }, as: :json
    assert_response :redirect
  end

  test "moves require login" do
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "done" } }, as: :json
    # Format-aware auth (OPSEC-046): AJAX/JSON gets a clean 401, not an HTML redirect.
    assert_response :unauthorized
  end

  # === JSON requests work without CSRF token ===

  test "JSON PATCH works without CSRF token" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "queued" } }, as: :json
    assert_response :success
  end

  # === Reorder ===

  test "reorder sets positions in order" do
    log_in_as(@admin)
    # Create two tasks in same stage
    t1 = Task.create!(title: "Reorder A", stage: "new")
    t2 = Task.create!(title: "Reorder B", stage: "new")

    # Reorder: B before A
    post reorder_tasks_path(format: :json),
         params: { slugs: [t2.slug, t1.slug] }, as: :json
    assert_response :success

    t1.reload
    t2.reload
    assert_equal 1, t1.position
    assert_equal 0, t2.position
  end

  test "reorder requires admin" do
    log_in_as(@viewer)
    post reorder_tasks_path(format: :json),
         params: { slugs: [@new_task.slug] }, as: :json
    assert_response :redirect
  end

  test "reorder requires login" do
    post reorder_tasks_path(format: :json),
         params: { slugs: [@new_task.slug] }, as: :json
    assert_response :unauthorized
  end
end
