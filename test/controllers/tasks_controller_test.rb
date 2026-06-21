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

  test "deployments shows the current-release header when a release exists" do
    rel = Release.open!(branch: "release/header-test", qa_url: "https://qa.example/tasks", deployed_sha: "abc1234def567")
    @new_task.update!(stage: "reviewed")
    rel.add(@new_task)
    rel.assemble!

    get deployments_path

    assert_response :success
    assert_select "#current-release"
    assert_select "#current-release", text: /#{Regexp.escape(rel.slug)}/
    assert_select "#current-release", text: /assembled/ # state badge (scoped, not the column label)
    assert_select "#current-release a[href=?]", task_path(@new_task.slug) # member chip
    # "when present" fields render
    assert_select "#current-release a[href=?]", "https://qa.example/tasks" # QA link
    assert_includes response.body, "abc1234" # deployed SHA (7-char)
  end

  test "deployments omits the release header when there is no release" do
    Release.delete_all

    get deployments_path

    assert_response :success
    assert_select "#current-release", count: 0
  end

  test "tasks board shows only the Build-lane columns and no release module" do
    Release.open!(branch: "release/build-only") # a release exists, but /tasks must not show it
    get tasks_path

    assert_response :success
    assert_select "h2", "Tasks"
    # Feature-agent lane (+ archived toggle column); submitted is the seam
    assert_select "#dropzone-designed"
    assert_select "#dropzone-building"
    assert_select "#dropzone-blocked"
    assert_select "#dropzone-submitted"
    assert_select "#dropzone-archived"
    # DevOps-only columns absent
    assert_select "#dropzone-reviewed", count: 0
    assert_select "#dropzone-assembled", count: 0
    assert_select "#dropzone-shipped", count: 0
    # the current-release module + kickoff chips live on /deployments, not here
    assert_select "#current-release", count: 0
    assert_not_includes response.body, "Review submitted PRs"
    assert_not_includes response.body, "Run Deployment"
  end

  test "deployments board shows only the Deploy-lane columns" do
    get deployments_path

    assert_response :success
    assert_select "h2", "Deployments"
    # DevOps lane; submitted is the seam (shared with the feature-agent lane)
    assert_select "#dropzone-submitted"
    assert_select "#dropzone-reviewed"
    assert_select "#dropzone-assembled"
    assert_select "#dropzone-shipped"
    # feature-agent-only columns absent
    assert_select "#dropzone-designed", count: 0
    assert_select "#dropzone-building", count: 0
    assert_select "#dropzone-blocked", count: 0
    assert_select "#dropzone-archived", count: 0
    # copy-paste kickoff commands sit on the column headers
    assert_includes response.body, "Review submitted PRs"
    assert_includes response.body, "Run Deployment"
  end

  test "stages page renders both workflow lanes and the stage guide" do
    get stages_path

    assert_response :success
    assert_select "h2", "Stages"
    assert_select "h3", text: /Workflow 1 . Build/
    assert_select "h3", text: /Workflow 2 . Deploy/
    # a stage from each lane, and the responsible/next scaffolding
    assert_includes response.body, "Designed"
    assert_includes response.body, "Assembled"
    assert_includes response.body, "Responsible"
    assert_includes response.body, "Run Deployment" # DevOps kickoff chip on the assembled card
  end

  test "deployments and stages are public (no login required)" do
    get deployments_path
    assert_response :success
    get stages_path
    assert_response :success
  end

  test "each board page cross-links to the other two" do
    [tasks_path, deployments_path, stages_path].each do |page|
      get page
      assert_response :success
      assert_select %(nav a[href="#{tasks_path}"]), { minimum: 1 }, "#{page} missing Tasks nav link"
      assert_select %(nav a[href="#{deployments_path}"]), { minimum: 1 }, "#{page} missing Deployments nav link"
      assert_select %(nav a[href="#{stages_path}"]), { minimum: 1 }, "#{page} missing Stages nav link"
    end
  end

  test "board pages link back to the dashboard for admins" do
    log_in_as(@admin)
    [tasks_path, deployments_path, stages_path].each do |page|
      get page
      assert_select %(a[href="#{admin_dashboard_path}"]), { minimum: 1 }, "#{page} missing Dashboard link for admin"
    end
  end

  test "dashboard link is hidden from non-admins" do
    get tasks_path
    assert_select %(a[href="#{admin_dashboard_path}"]), count: 0
  end

  test "index shows DevOps Cycle link for admins" do
    log_in_as(@admin)

    get tasks_path

    assert_response :success
    assert_select "a[href=?]", devops_cycle_path, text: "DevOps Cycle"
  end

  test "index hides DevOps Cycle link from non-admins" do
    get tasks_path

    assert_response :success
    assert_select "a[href=?]", devops_cycle_path, count: 0
  end

  test "index renders latest task feedback on cards" do
    Activity.create!(
      task_slug: @new_task.slug,
      activity_type: "comment",
      description: "Older note."
    )
    Activity.create!(
      task_slug: @new_task.slug,
      activity_type: "qa_feedback",
      description: "Latest QA note should appear on the board."
    )

    get tasks_path

    assert_response :success
    assert_includes response.body, "Latest QA note should appear on the board."
    assert_includes response.body, "2 notes"
  end

  test "show renders task detail" do
    get task_path(@new_task.slug)
    assert_response :success
  end

  # === Kanban stage moves via JSON PATCH (the one path: board, bin/task, API) ===

  test "move task to any stage via PATCH JSON" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "shipped" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "shipped", @new_task.stage
    assert_not_nil @new_task.completed_at
  end

  test "move task backwards via PATCH JSON" do
    log_in_as(@admin)
    patch task_path(@done_task.slug, format: :json),
          params: { task: { stage: "designed" } }, as: :json
    assert_response :success
    @done_task.reload
    assert_equal "designed", @done_task.stage
  end

  test "move task to building sets started_at" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "building" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "building", @new_task.stage
    assert_not_nil @new_task.started_at
  end

  test "move task through the build workflow stages" do
    log_in_as(@admin)

    %w[building submitted reviewed].each do |stage|
      patch task_path(@new_task.slug, format: :json),
            params: { task: { stage: stage } }, as: :json
      assert_response :success
      assert_equal stage, @new_task.reload.stage
    end
    assert_not_nil @new_task.submitted_at
    assert_not_nil @new_task.reviewed_at
  end

  test "move task through the deploy workflow stages" do
    log_in_as(@admin)

    %w[reviewed assembled shipped].each do |stage|
      patch task_path(@new_task.slug, format: :json),
            params: { task: { stage: stage } }, as: :json
      assert_response :success
      assert_equal stage, @new_task.reload.stage
    end
    assert_not_nil @new_task.assembled_at
    assert_not_nil @new_task.completed_at
  end

  test "move task to blocked sets blocked_at and captures blocked_from" do
    log_in_as(@admin)
    patch task_path(@in_progress_task.slug, format: :json),
          params: { task: { stage: "blocked" } }, as: :json
    assert_response :success
    @in_progress_task.reload
    assert_equal "blocked", @in_progress_task.stage
    assert_not_nil @in_progress_task.blocked_at
    assert_equal "building", @in_progress_task.blocked_from
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
            worktree_slug: "contest-flow",
            repositories: "turf-monster, turf-vault",
            branch: "feat/contest-flow",
            pr_url: "https://github.com/amcritchie/turf-monster/pull/149",
            qa_url: "https://qa.turfmonster.media/contests",
            release_train: "2026-06-17-turf",
            requires_release_conductor: "1",
            acceptance: "Contest creates on QA\nEntry submits on QA",
            test_plan: "bin/rails test\nQA devnet mutating smoke",
            checks_run: "bin/rails test test/controllers/tasks_controller_test.rb"
          }
        }
      }
    end

    task = Task.order(:created_at).last
    assert_redirected_to task_path(task.slug)
    assert task.requires_release_conductor?
    assert_equal "contest-flow", task.devops_worktree_slug
    assert_equal ["turf-monster", "turf-vault"], task.devops_repositories
    assert_equal ["Contest creates on QA", "Entry submits on QA"], task.devops_acceptance
    assert_equal ["bin/rails test test/controllers/tasks_controller_test.rb"], task.devops_checks_run
    assert_equal "https://qa.turfmonster.media/contests", task.devops_url(:qa)
  end

  test "show renders devops handoff details" do
    @new_task.update!(
      metadata: {
        "devops" => {
          "kind" => "release",
          "worktree_slug" => "task-board-release",
          "repositories" => ["mcritchie-studio"],
          "qa_url" => "https://qa.mcritchie.studio/tasks",
          "acceptance" => ["Task board shows release metadata"],
          "test_plan" => ["PR review gate"],
          "checks_run" => ["bin/rails test"]
        }
      }
    )

    get task_path(@new_task.slug)

    assert_response :success
    assert_select ".label-upper", "DevOps handoff"
    assert_includes response.body, "task-board-release"
    assert_select "a[href=?]", "https://qa.mcritchie.studio/tasks"
    assert_includes response.body, "Task board shows release metadata"
    assert_includes response.body, "Expected Test Plan"
    assert_includes response.body, "Checks Run"
    assert_includes response.body, "bin/rails test"
  end

  test "show renders task conversation" do
    Activity.create!(
      task_slug: @new_task.slug,
      agent_slug: "alex",
      activity_type: "qa_feedback",
      description: "QA blocked until the sidebar branch is rebased."
    )

    get task_path(@new_task.slug)

    assert_response :success
    assert_select ".label-upper", "Conversation"
    assert_includes response.body, "QA blocked until the sidebar branch is rebased."
    assert_not_includes response.body, "Activity feed"
  end

  test "admin sees task feedback form" do
    log_in_as(@admin)

    get task_path(@new_task.slug)

    assert_response :success
    assert_select "form[action=?]", comment_task_path(@new_task.slug)
    assert_select "textarea[name='activity[description]']"
    assert_select "select[name='activity[activity_type]']"
  end

  test "admin can add task feedback from show page" do
    log_in_as(@admin)

    assert_difference "Activity.count", 1 do
      post comment_task_path(@new_task.slug),
           params: {
             activity: {
               activity_type: "qa_feedback",
               description: "Please address the QA browser-back regression."
             }
           }
    end

    assert_redirected_to task_path(@new_task.slug)
    activity = Activity.order(:created_at).last
    assert_equal @new_task.slug, activity.task_slug
    assert_equal "qa_feedback", activity.activity_type
    assert_equal "alex", activity.agent_slug
    assert_equal "task_conversation", activity.metadata["source"]
  end

  test "task feedback requires admin" do
    log_in_as(@viewer)

    assert_no_difference "Activity.count" do
      post comment_task_path(@new_task.slug),
           params: {
             activity: {
               activity_type: "qa_feedback",
               description: "Viewer feedback should not be accepted."
             }
           }
    end

    assert_response :redirect
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
          params: { task: { stage: "submitted" } }, as: :json
    assert_response :success
  end

  # === Reorder ===

  test "reorder sets positions in order" do
    log_in_as(@admin)
    # Create two tasks in same stage
    t1 = Task.create!(title: "Reorder A", stage: "designed")
    t2 = Task.create!(title: "Reorder B", stage: "designed")

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
