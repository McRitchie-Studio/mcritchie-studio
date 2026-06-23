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
    assert_equal "test-slug-generation", task.slug # derives from the title now
  end

  test "slug is immutable after creation" do
    task = tasks(:new_task)
    original_slug = task.slug
    task.update!(title: "now a changed title")
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
    t1 = Task.create!(title: "first designed task here", stage: "designed")
    t2 = Task.create!(title: "second designed task here", stage: "designed")
    assert t2.position > t1.position
  end

  test "tasks default to the designed stage" do
    task = Task.create!(title: "default stage check task")
    assert_equal "designed", task.stage
  end

  # --- Sizing (sealed-bid) ---

  test "size columns accept all valid t-shirt sizes" do
    task = Task.create!(title: "sizing test sample task")
    Task::SIZES.each do |size|
      %i[pm_size po_size dev_size actual_size].each do |col|
        task.update!(col => size)
        assert_equal size, task.public_send(col)
      end
    end
  end

  test "size columns reject invalid sizes" do
    task = Task.new(title: "bad size value task", pm_size: "huge")
    assert_not task.valid?
    assert_includes task.errors[:pm_size], "is not included in the list"
  end

  test "size columns allow nil" do
    task = Task.create!(title: "no sizes set task")
    assert_nil task.pm_size
    assert_nil task.po_size
    assert_nil task.dev_size
    assert_nil task.actual_size
    assert task.valid?
  end

  # --- requires_migration ---

  test "requires_migration scope returns only flagged tasks" do
    flagged = Task.create!(title: "needs migration flag task", requires_migration: true)
    Task.create!(title: "no migration flag task")
    assert_includes Task.requires_migration, flagged
    assert_equal 1, Task.requires_migration.where(title: ["needs migration flag task", "no migration flag task"]).count
  end

  test "requires_migration defaults to false" do
    task = Task.create!(title: "default flag check task")
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

  # --- Slug: explicit override, else derived from the (terse) title ---

  test "an explicit slug becomes the readable, parameterized Task.slug" do
    task = Task.create!(title: "valid four word title", slug: "Standard Link Model")
    assert_equal "standard-link-model", task.slug
  end

  test "no explicit slug derives the slug from the title" do
    task = Task.create!(title: "Derive slug from title")
    assert_equal "derive-slug-from-title", task.slug
  end

  test "title-derived slugs auto-suffix to stay unique" do
    first = Task.create!(title: "Same short title")
    second = Task.create!(title: "Same short title")
    assert_equal "same-short-title", first.slug
    assert_equal "same-short-title-2", second.slug
  end

  test "an unparameterizable title falls back to hex and does not trickle" do
    task = Task.create!(title: "### @@@ %%%") # 3 'words', parameterizes to blank
    assert_match(/\Atask-[0-9a-f]{12}\z/, task.slug)
    assert_nil task.devops_worktree_slug
  end

  test "the slug seeds worktree_slug and branch (trickle-down)" do
    task = Task.create!(title: "Readable handle here")
    assert_equal "readable-handle-here", task.devops_worktree_slug
    assert_equal "feat/readable-handle-here", task.metadata.dig("devops", "branch")
  end

  test "explicit worktree_slug/branch are not overwritten by the trickle-down" do
    task = Task.create!(title: "Readable handle here", slug: "readable-handle",
                        metadata: { "devops" => { "worktree_slug" => "custom-wt", "branch" => "feat/custom" } })
    assert_equal "custom-wt", task.devops_worktree_slug
    assert_equal "feat/custom", task.metadata.dig("devops", "branch")
  end

  test "slug is immutable after creation (attr_readonly raises on update)" do
    task = Task.create!(title: "Immutable slug test", slug: "original")
    assert_raises(ActiveRecord::ReadonlyAttributeError) { task.update!(slug: "changed") }
    assert_equal "original", task.reload.slug
  end

  test "a duplicate explicit slug is rejected" do
    Task.create!(title: "First dupe task", slug: "dupe")
    dup = Task.new(title: "Second dupe task", slug: "dupe")
    assert_not dup.valid?
    assert_includes dup.errors[:slug], "has already been taken"
  end

  # --- release_repo / gem_release? / release_kind ---

  test "release_repo parses the repo from a github PR url" do
    task = Task.create!(title: "engine version bump task", stage: "reviewed",
                        metadata: { "devops" => { "pr_url" => "https://github.com/amcritchie/studio-engine/pull/9" } })
    assert_equal "studio-engine", task.release_repo
    assert task.gem_release?
    assert_equal :gem, task.release_kind
  end

  test "release_repo prefers the PR url over the declared repositories" do
    task = Task.create!(title: "mixed repo source task", stage: "reviewed",
                        metadata: { "devops" => {
                          "pr_url" => "https://github.com/amcritchie/solana-studio/pull/3",
                          "repositories" => ["turf-monster"]
                        } })
    assert_equal "solana-studio", task.release_repo
    assert task.gem_release?
  end

  test "a library-shape task is a gem release via its declared gem repo" do
    task = Task.create!(title: "engine UI primitive", stage: "reviewed",
                        metadata: { "devops" => { "shape" => "library", "repositories" => ["studio-engine"] } })
    assert_equal "studio-engine", task.release_repo
    assert task.gem_release?
    assert_equal :gem, task.release_kind
  end

  test "a library-shape task is a gem release even with no resolvable gem repo" do
    task = Task.create!(title: "library no repos", stage: "reviewed",
                        metadata: { "devops" => { "shape" => "library" } })
    assert task.gem_release?, "library shape is always a gem release"
    assert_equal :gem, task.release_kind
  end

  test "an app task is not a gem release" do
    task = Task.create!(title: "app feature release task", stage: "reviewed",
                        metadata: { "devops" => {
                          "shape" => "backend",
                          "repositories" => ["mcritchie-studio"],
                          "pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/77"
                        } })
    assert_equal "mcritchie-studio", task.release_repo
    assert_not task.gem_release?
    assert_equal :app, task.release_kind
  end

  test "a task with no repo metadata classifies as unknown, not a gem" do
    task = Task.create!(title: "bare task no repo", stage: "reviewed")
    assert_nil task.release_repo
    assert_not task.gem_release?
    assert_equal :unknown, task.release_kind
  end

  # --- Naming discipline: terse title + acceptance, agent_context ---

  test "title must be 3-5 words on create" do
    assert Task.new(title: "fix the login").valid?               # 3
    assert Task.new(title: "add a new login flow").valid?        # 5
    assert_not Task.new(title: "fix login").valid?               # 2
    assert_not Task.new(title: "add a brand new login flow now").valid? # 7
  end

  test "an existing task is grandfathered until its title actually changes" do
    task = Task.create!(title: "valid four word title")
    task.update!(stage: "building") # title untouched → not re-validated
    assert_equal "building", task.reload.stage
    assert_raises(ActiveRecord::RecordInvalid) do
      task.update!(title: "now this title has far too many words to pass") # 9
    end
  end

  test "each acceptance bullet must be 5-12 words on create" do
    ok = Task.new(title: "acceptance length check",
                  metadata: { "devops" => { "acceptance" => ["the user can log in successfully"] } }) # 6
    assert ok.valid?
    short = Task.new(title: "acceptance length check",
                     metadata: { "devops" => { "acceptance" => ["too short here"] } }) # 3
    assert_not short.valid?
  end

  test "acceptance is validated on change but unrelated devops updates are grandfathered" do
    task = Task.create!(title: "acceptance change task",
                        metadata: { "devops" => { "acceptance" => ["the user can log in successfully"] } })
    task.update!(metadata: task.metadata.deep_merge("devops" => { "kind" => "bug" })) # acceptance untouched
    assert_equal "bug", task.devops_kind
    assert_raises(ActiveRecord::RecordInvalid) do
      task.update!(metadata: task.metadata.deep_merge("devops" => { "acceptance" => ["too short"] })) # 2
    end
  end

  test "agent_context stores free-form verbose detail" do
    task = Task.create!(title: "agent context round trip",
                        metadata: { "devops" => { "agent_context" => "Verbose multi-line\nreasoning for agents." } })
    assert_equal "Verbose multi-line\nreasoning for agents.", task.devops_agent_context
  end

  # --- Session resume (V1: store + display + copy) ---

  test "normalize keeps session_id and session_provider (accepted by the API)" do
    metadata = Task.normalize_devops_metadata(
      "session_id" => "2aa216f6-7565-4bf4-bd01-70793c8ba617",
      "session_provider" => "claude"
    )
    assert_equal "2aa216f6-7565-4bf4-bd01-70793c8ba617", metadata["session_id"]
    assert_equal "claude", metadata["session_provider"]
  end

  test "session_id_last4 returns the trailing four chars, nil-safe" do
    with_session = Task.new(title: "session last four",
                            metadata: { "devops" => { "session_id" => "abcd-1234-12ab" } })
    assert_equal "12ab", with_session.session_id_last4

    without = Task.new(title: "no session here")
    assert_nil without.session_id_last4
  end

  test "resume_command builds the claude command from the full session id" do
    task = Task.new(title: "resume claude command",
                    metadata: { "devops" => { "session_id" => "sess-12ab", "session_provider" => "claude" } })
    assert_equal "claude --resume sess-12ab", task.resume_command
  end

  test "resume_command builds the codex command for a codex session" do
    task = Task.new(title: "resume codex command",
                    metadata: { "devops" => { "session_id" => "sess-99zz", "session_provider" => "codex" } })
    assert_equal "codex resume sess-99zz", task.resume_command
  end

  test "resume_command treats a missing provider as claude" do
    task = Task.new(title: "resume default provider",
                    metadata: { "devops" => { "session_id" => "sess-77yy" } })
    assert_equal "claude --resume sess-77yy", task.resume_command
  end

  test "resume_command falls back to claude for an unknown provider" do
    task = Task.new(title: "resume unknown provider",
                    metadata: { "devops" => { "session_id" => "sess-55xx", "session_provider" => "vim" } })
    assert_equal "claude --resume sess-55xx", task.resume_command
  end

  test "resume_command is nil when there is no session id" do
    assert_nil Task.new(title: "no session command").resume_command
  end

  test "resume_command_display truncates to the verb plus last four" do
    claude = Task.new(title: "display claude command",
                      metadata: { "devops" => { "session_id" => "long-session-12ab" } })
    assert_equal "claude --resume …12ab", claude.resume_command_display

    codex = Task.new(title: "display codex command",
                     metadata: { "devops" => { "session_id" => "long-session-99zz", "session_provider" => "codex" } })
    assert_equal "codex resume …99zz", codex.resume_command_display
  end

  test "resume_command_display is nil when there is no session id" do
    assert_nil Task.new(title: "no session display").resume_command_display
  end

  # --- Pokémon mascot (a fun, unique, per-task identifier) ---

  def seed_pokemon(*slugs)
    slugs.each_with_index { |s, i| Pokemon.create!(dex: 900 + i, name: s.capitalize, slug: s, generation: 1) }
  end

  test "create assigns a Pokemon mascot from the deck" do
    seed_pokemon("snorlax", "pikachu", "eevee")
    task = Task.create!(title: "Mascot assignment test task")
    assert_includes %w[snorlax pikachu eevee], task.devops["mascot"]
  end

  test "mascot is unique among live tasks" do
    seed_pokemon("snorlax", "pikachu")
    first = Task.create!(title: "First live mascot task")
    second = Task.create!(title: "Second live mascot task")
    assert_not_equal first.devops["mascot"], second.devops["mascot"]
  end

  test "an explicit mascot override is preserved" do
    seed_pokemon("snorlax")
    task = Task.create!(title: "Override mascot test task",
                        metadata: { "devops" => { "mascot" => "ditto" } })
    assert_equal "ditto", task.devops["mascot"]
  end

  test "active_mascots excludes shipped and archived tasks" do
    seed_pokemon("snorlax", "pikachu", "eevee")
    live = Task.create!(title: "Live mascot holder task")
    shipped = Task.create!(title: "Shipped mascot holder task")
    shipped.update!(stage: "shipped")

    assert_includes Task.active_mascots, live.devops["mascot"]
    assert_not_includes Task.active_mascots, shipped.devops["mascot"]
  end

  test "create leaves mascot unset when the deck is unseeded" do
    task = Task.create!(title: "No deck mascot task")
    assert_nil task.devops["mascot"]
  end

  # --- reviewers (two-senior review metadata) ---------------------------------

  test "reviewers is empty for an old-flow task without the metadata" do
    assert_equal [], Task.new(title: "no reviewers meta task").reviewers
  end

  test "reviewers normalizes hashes, slug strings, and aliases; drops blanks" do
    task = Task.new(title: "reviewers shape task", metadata: { "reviewers" => [
      { "slug" => "shannon", "weight" => "heavy" },
      { "agent_slug" => " carl ", "depth" => "light" },  # aliases + whitespace
      { "slug" => "steffon", "review_weight" => "heavy" }, # souls-seed key
      "jasper",                                           # bare slug string
      { "slug" => "" },                                   # blank slug, dropped
      { "weight" => "heavy" }                             # no slug, dropped
    ] })

    assert_equal(
      [
        { "slug" => "shannon", "weight" => "heavy" },
        { "slug" => "carl",    "weight" => "light" },
        { "slug" => "steffon", "weight" => "heavy" },
        { "slug" => "jasper",  "weight" => nil }
      ],
      task.reviewers
    )
  end
end
