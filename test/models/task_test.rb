require "test_helper"

class TaskTest < ActiveSupport::TestCase
  # --- Valid transitions ---

  test "new task can be queued" do
    task = tasks(:new_task)
    task.queue!
    assert_equal "queued", task.stage
    assert_not_nil task.queued_at
  end

  test "queued task can be started" do
    task = tasks(:queued_task)
    task.start!
    assert_equal "in_progress", task.stage
    assert_not_nil task.started_at
  end

  test "queued task can be failed" do
    task = tasks(:queued_task)
    task.fail!("dependency missing")
    assert_equal "failed", task.stage
    assert_not_nil task.failed_at
    assert_equal "dependency missing", task.error_message
  end

  test "in_progress task can be completed" do
    task = tasks(:in_progress_task)
    task.complete!({ output: "done" })
    assert_equal "done", task.stage
    assert_not_nil task.completed_at
    assert_equal({ "output" => "done" }, task.result)
  end

  test "in_progress task can be failed" do
    task = tasks(:in_progress_task)
    task.fail!("crash")
    assert_equal "failed", task.stage
  end

  test "done task can be archived" do
    task = tasks(:done_task)
    task.archive!
    assert_equal "archived", task.stage
    assert_not_nil task.archived_at
  end

  test "failed task can be archived" do
    task = tasks(:failed_task)
    task.archive!
    assert_equal "archived", task.stage
  end

  test "failed task can be requeued" do
    task = tasks(:failed_task)
    task.queue!
    assert_equal "queued", task.stage
  end

  # --- Free movement (no transition restrictions) ---

  test "task can move to any stage" do
    task = tasks(:new_task)
    task.start!
    assert_equal "in_progress", task.stage
    task.update!(stage: "pr_review")
    assert_equal "pr_review", task.stage
    task.update!(stage: "qa_review")
    assert_equal "qa_review", task.stage
    task.update!(stage: "prod_ready")
    assert_equal "prod_ready", task.stage
    task.complete!
    assert_equal "done", task.stage
    task.queue!
    assert_equal "queued", task.stage
  end

  test "all task stages are valid" do
    Task::STAGES.each do |stage|
      task = Task.new(title: "Task in #{stage}", stage: stage)
      assert task.valid?, "#{stage} should be valid"
    end
  end

  test "stage labels expose DevOps pipeline names" do
    assert_equal "PR Review", Task::STAGE_LABELS.fetch("pr_review")
    assert_equal "QA Review", Task::STAGE_LABELS.fetch("qa_review")
    assert_equal "Prod Ready", Task::STAGE_LABELS.fetch("prod_ready")
    assert_equal "Shipped", Task::STAGE_LABELS.fetch("done")
  end

  test "stage change sets appropriate timestamp" do
    task = tasks(:new_task)
    task.update!(stage: "done")
    assert_not_nil task.completed_at
    task.update!(stage: "failed")
    assert_not_nil task.failed_at
  end

  # --- Slug ---

  test "slug is generated on create" do
    task = Task.create!(title: "Test slug generation")
    assert task.slug.present?
    assert task.slug.start_with?("task-")
  end

  test "slug is immutable after creation" do
    task = tasks(:new_task)
    original_slug = task.slug
    task.update!(title: "Changed title")
    assert_equal original_slug, task.slug
  end

  test "to_param returns slug" do
    task = tasks(:new_task)
    assert_equal task.slug, task.to_param
  end

  # --- Position ---

  test "position is auto-set on create" do
    task = Task.create!(title: "Auto position test", stage: "new")
    assert_not_nil task.position
  end

  test "position resets when stage changes" do
    task = tasks(:new_task)
    original_position = task.position
    task.update!(stage: "queued")
    assert_equal "queued", task.stage
    assert_not_nil task.position
  end

  test "new tasks get appended to end of stage" do
    t1 = Task.create!(title: "First", stage: "new")
    t2 = Task.create!(title: "Second", stage: "new")
    assert t2.position > t1.position
  end

  # --- Sizing (sealed-bid) ---

  test "size columns accept all valid t-shirt sizes" do
    task = Task.create!(title: "Sizing test")
    Task::SIZES.each do |size|
      %i[pm_size po_size dev_size actual_size].each do |col|
        task.update!(col => size)
        assert_equal size, task.public_send(col)
      end
    end
  end

  test "size columns reject invalid sizes" do
    task = Task.new(title: "Bad size", pm_size: "huge")
    assert_not task.valid?
    assert_includes task.errors[:pm_size], "is not included in the list"
  end

  test "size columns allow nil" do
    task = Task.create!(title: "No sizes")
    assert_nil task.pm_size
    assert_nil task.po_size
    assert_nil task.dev_size
    assert_nil task.actual_size
    assert task.valid?
  end

  # --- requires_migration ---

  test "requires_migration scope returns only flagged tasks" do
    flagged = Task.create!(title: "Needs migration", requires_migration: true)
    Task.create!(title: "No migration")
    assert_includes Task.requires_migration, flagged
    assert_equal 1, Task.requires_migration.where(title: ["Needs migration", "No migration"]).count
  end

  test "requires_migration defaults to false" do
    task = Task.create!(title: "Default flag")
    assert_equal false, task.requires_migration
  end

  # --- Migration lane (advisory lock) ---

  test "migration lane helpers return booleans and execute cleanly" do
    acquired = Task.try_acquire_migration_lane
    assert_includes [true, false], acquired
    released = Task.release_migration_lane
    assert_includes [true, false], released
  end

  # --- DevOps metadata ---

  test "normalizes devops metadata lists from strings and arrays" do
    metadata = Task.normalize_devops_metadata(
      "repositories" => "mcritchie-studio, turf-monster\nstudio-engine",
      "risk_tags" => ["auth", "auth", "deploy"],
      "acceptance" => "QA URL works\nProduction stays gated",
      "branch" => " feat/example "
    )

    assert_equal ["mcritchie-studio", "turf-monster", "studio-engine"], metadata["repositories"]
    assert_equal ["auth", "deploy"], metadata["risk_tags"]
    assert_equal ["QA URL works", "Production stays gated"], metadata["acceptance"]
    assert_equal "feat/example", metadata["branch"]
  end

  test "array-form devops lists keep commas; string-form still splits on commas" do
    metadata = Task.normalize_devops_metadata(
      "acceptance" => ["Header stays pinned, even while scrolling", "Email still works"],
      "risk_tags" => "auth, deploy"
    )

    # Array items are preserved verbatim — a comma inside a sentence is kept.
    assert_equal ["Header stays pinned, even while scrolling", "Email still works"], metadata["acceptance"]
    # String (UI free-text) fields still split on comma and newline.
    assert_equal ["auth", "deploy"], metadata["risk_tags"]
  end

  test "devops helpers expose stored release metadata" do
    task = Task.create!(
      title: "Ship a feature",
      metadata: {
        "devops" => {
          "kind" => "bug",
          "repositories" => ["turf-monster"],
          "release_train" => "2026-06-17-turf",
          "qa_url" => "https://qa.turfmonster.media/contests",
          "requires_release_conductor" => "1",
          "test_plan" => ["bin/rails test"]
        }
      }
    )

    assert task.devops?
    assert task.requires_release_conductor?
    assert_equal "bug", task.devops_kind
    assert_equal ["turf-monster"], task.devops_repositories
    assert_equal "2026-06-17-turf", task.devops_release_train
    assert_equal "https://qa.turfmonster.media/contests", task.devops_url(:qa)
    assert_equal ["bin/rails test"], task.devops_test_plan
  end
end
