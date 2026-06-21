require "test_helper"

class TaskTest < ActiveSupport::TestCase
  # --- Workflow 1: Build transitions ---

  test "designed task can start building" do
    task = tasks(:new_task)
    task.build!
    assert_equal "building", task.stage
    assert_not_nil task.started_at
  end

  test "building task can be submitted" do
    task = tasks(:in_progress_task)
    task.submit!
    assert_equal "submitted", task.stage
    assert_not_nil task.submitted_at
  end

  test "submitted task can be reviewed" do
    task = tasks(:new_task)
    task.update!(stage: "submitted")
    task.review!
    assert_equal "reviewed", task.stage
    assert_not_nil task.reviewed_at
  end

  # --- Workflow 2: Deploy transitions ---

  test "reviewed task can be assembled" do
    task = tasks(:new_task)
    task.update!(stage: "reviewed")
    task.assemble!
    assert_equal "assembled", task.stage
    assert_not_nil task.assembled_at
  end

  test "assembled task can be shipped with result" do
    task = tasks(:new_task)
    task.update!(stage: "assembled")
    task.ship!({ output: "done" })
    assert_equal "shipped", task.stage
    assert_not_nil task.completed_at
    assert_equal({ "output" => "done" }, task.result)
  end

  # --- blocked side state ---

  test "a task can be blocked, capturing where it came from and why" do
    task = tasks(:in_progress_task) # building
    task.block!(kind: "rework")
    assert task.blocked?
    assert_equal "blocked", task.stage
    assert_not_nil task.blocked_at
    assert_equal "building", task.blocked_from
    assert_equal "rework", task.block_kind
  end

  test "a blocked task can resume building" do
    task = tasks(:failed_task) # blocked
    task.build!
    assert_equal "building", task.stage
  end

  # --- terminal ---

  test "a shipped task can be archived" do
    task = tasks(:done_task)
    task.archive!
    assert_equal "archived", task.stage
    assert_not_nil task.archived_at
  end

  # --- Free movement (no transition restrictions) ---

  test "task can move freely across the two workflows" do
    task = tasks(:new_task)
    %w[building submitted reviewed assembled shipped].each do |stage|
      task.update!(stage: stage)
      assert_equal stage, task.stage
    end
  end

  test "all task stages are valid" do
    Task::STAGES.each do |stage|
      task = Task.new(title: "Task in #{stage}", stage: stage)
      assert task.valid?, "#{stage} should be valid"
    end
  end

  test "stage labels expose two-workflow names" do
    assert_equal "Designed", Task::STAGE_LABELS.fetch("designed")
    assert_equal "Submitted", Task::STAGE_LABELS.fetch("submitted")
    assert_equal "Reviewed", Task::STAGE_LABELS.fetch("reviewed")
    assert_equal "Assembled", Task::STAGE_LABELS.fetch("assembled")
    assert_equal "Shipped", Task::STAGE_LABELS.fetch("shipped")
    assert_equal "Blocked", Task::STAGE_LABELS.fetch("blocked")
  end

  test "build and deploy stage groups share the submitted seam" do
    assert_includes Task::BUILD_STAGES, "submitted"
    assert_includes Task::DEPLOY_STAGES, "submitted"
    assert_equal "designed", Task::BUILD_STAGES.first
    assert_equal "shipped", Task::DEPLOY_STAGES.last
  end

  test "stage change sets the appropriate timestamp" do
    task = tasks(:new_task)
    task.update!(stage: "submitted")
    assert_not_nil task.submitted_at
    task.update!(stage: "shipped")
    assert_not_nil task.completed_at
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
    task = Task.create!(title: "Auto position test", stage: "designed")
    assert_not_nil task.position
  end

  test "position resets when stage changes" do
    task = tasks(:new_task)
    task.update!(stage: "building")
    assert_equal "building", task.stage
    assert_not_nil task.position
  end

  test "new tasks get appended to end of stage" do
    t1 = Task.create!(title: "First", stage: "designed")
    t2 = Task.create!(title: "Second", stage: "designed")
    assert t2.position > t1.position
  end

  test "tasks default to the designed stage" do
    task = Task.create!(title: "Default stage")
    assert_equal "designed", task.stage
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
      "checks_run" => "bin/rails test\nbin/rubocop",
      "branch" => " feat/example ",
      "worktree_slug" => " task-board-contract "
    )

    assert_equal ["mcritchie-studio", "turf-monster", "studio-engine"], metadata["repositories"]
    assert_equal ["auth", "deploy"], metadata["risk_tags"]
    assert_equal ["QA URL works", "Production stays gated"], metadata["acceptance"]
    assert_equal ["bin/rails test", "bin/rubocop"], metadata["checks_run"]
    assert_equal "feat/example", metadata["branch"]
    assert_equal "task-board-contract", metadata["worktree_slug"]
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

  test "block_kind normalizes through devops metadata" do
    metadata = Task.normalize_devops_metadata("block_kind" => "environment")
    assert_equal "environment", metadata["block_kind"]
  end

  test "devops helpers expose stored release metadata" do
    task = Task.create!(
      title: "Ship a feature",
      metadata: {
        "devops" => {
          "kind" => "bug",
          "worktree_slug" => "qa-contest-flow",
          "repositories" => ["turf-monster"],
          "release_train" => "2026-06-17-turf",
          "qa_url" => "https://qa.turfmonster.media/contests",
          "requires_release_conductor" => "1",
          "test_plan" => ["bin/rails test"],
          "checks_run" => ["bin/rails test test/models/task_test.rb"]
        }
      }
    )

    assert task.devops?
    assert task.requires_release_conductor?
    assert_equal "bug", task.devops_kind
    assert_equal "qa-contest-flow", task.devops_worktree_slug
    assert_equal ["turf-monster"], task.devops_repositories
    assert_equal "2026-06-17-turf", task.devops_release_train
    assert_equal "https://qa.turfmonster.media/contests", task.devops_url(:qa)
    assert_equal ["bin/rails test"], task.devops_test_plan
    assert_equal ["bin/rails test test/models/task_test.rb"], task.devops_checks_run
  end

  # --- Readable slug: custom handle at creation, trickle-down ---

  test "a provided slug becomes the readable, parameterized Task.slug" do
    task = Task.create!(title: "X", slug: "Standard Link Model")
    assert_equal "standard-link-model", task.slug
  end

  test "no slug falls back to an opaque task-<hex>" do
    task = Task.create!(title: "X")
    assert_match(/\Atask-[0-9a-f]{12}\z/, task.slug)
  end

  test "a custom slug seeds worktree_slug and branch (trickle-down)" do
    task = Task.create!(title: "X", slug: "readable-handle")
    assert_equal "readable-handle", task.devops_worktree_slug
    assert_equal "feat/readable-handle", task.metadata.dig("devops", "branch")
  end

  test "explicit worktree_slug/branch are not overwritten by the trickle-down" do
    task = Task.create!(title: "X", slug: "readable-handle",
                        metadata: { "devops" => { "worktree_slug" => "custom-wt", "branch" => "feat/custom" } })
    assert_equal "custom-wt", task.devops_worktree_slug
    assert_equal "feat/custom", task.metadata.dig("devops", "branch")
  end

  test "an opaque hex slug does not trickle into worktree_slug/branch" do
    task = Task.create!(title: "X")
    assert_nil task.devops_worktree_slug
    assert_nil task.metadata.dig("devops", "branch")
  end

  test "slug is immutable after creation (attr_readonly raises on update)" do
    task = Task.create!(title: "X", slug: "original")
    assert_raises(ActiveRecord::ReadonlyAttributeError) { task.update!(slug: "changed") }
    assert_equal "original", task.reload.slug
  end

  test "a duplicate slug is rejected" do
    Task.create!(title: "A", slug: "dupe")
    dup = Task.new(title: "B", slug: "dupe")
    assert_not dup.valid?
    assert_includes dup.errors[:slug], "has already been taken"
  end
end
