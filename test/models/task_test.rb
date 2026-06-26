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

  # --- builder identity: who built this (devops.built_by) ---

  test "moving to building stamps the build-claim actor onto devops.built_by" do
    Current.task_event_actor = "carl"
    task = tasks(:new_task)
    task.build!

    assert_equal "carl", task.reload.devops_built_by, "the build agent is recorded for reviewer exclusion"
  ensure
    Current.reset
  end

  test "a building move with no actor and no assignee leaves built_by unset" do
    # new_task has no Current actor AND no agent_slug — neither the actor nor the
    # assigned-agent fallback can resolve a soul, so nothing is stamped and an
    # existing value is never clobbered to nil.
    task = tasks(:new_task)
    assert_nil task.agent_slug, "guards the assumption: no assignee to fall back to"
    task.build!

    assert_nil task.reload.devops_built_by
  end

  test "a rework re-claim re-points built_by to the current builder" do
    Current.task_event_actor = "shannon"
    task = tasks(:new_task)
    task.build!
    assert_equal "shannon", task.reload.devops_built_by

    # Bounced back, then re-claimed by a different soul — built_by follows.
    task.update!(stage: "blocked")
    Current.task_event_actor = "carl"
    task.update!(stage: "building")

    assert_equal "carl", task.reload.devops_built_by, "the latest builder wins on a re-claim"
  ensure
    Current.reset
  end

  test "a soul-slug build actor is stamped and excluded from review end-to-end" do
    # The real build path passes --actor <soul>; the soul is stamped and the
    # reviewer pool then excludes it (a soul never reviews their own work).
    Current.task_event_actor = "carl"
    task = Task.create!(title: "soul builder exclusion task",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    assert_equal "carl", task.reload.devops_built_by, "a soul slug is recorded as the builder"

    decision = ReviewerSelector.explain(task)
    assert_equal "carl", decision["excluded_builder"], "the soul builder is excluded from review"
    refute_includes decision["candidates"], "carl"
  ensure
    Current.reset
  end

  test "a session-id build actor is not stamped and causes no false exclusion" do
    # A bare `bin/task move <slug> building` defaults the actor to the session id
    # (a UUID) — NOT a soul. It must not be stamped as built_by, and must not be
    # reported as excluded (it was never a reviewer candidate). This is the gap
    # that made the feature no-op on the CLI build path while the audit lied.
    Current.task_event_actor = "942a9824-375f-4d13-b60e-85be79ee9880"
    task = Task.create!(title: "session id builder task",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    assert_nil task.reload.devops_built_by, "a session id is not stamped as the builder"

    decision = ReviewerSelector.explain(task)
    assert_nil decision["excluded_builder"], "no soul is falsely excluded"
    assert_includes decision["candidates"], "carl", "the full pool (minus QA owner) stays eligible"
  ensure
    Current.reset
  end

  test "a no-actor re-move to building preserves the existing built_by" do
    # Set a builder, bounce to blocked, then re-move to building with NO actor
    # (Current cleared) — stamp_builder must leave the prior builder untouched,
    # never clobber it to nil.
    Current.task_event_actor = "shannon"
    task = tasks(:new_task)
    task.build!
    assert_equal "shannon", task.reload.devops_built_by
    Current.reset # the re-claim below carries no actor

    task.update!(stage: "blocked")
    task.update!(stage: "building")

    assert_equal "shannon", task.reload.devops_built_by,
      "a no-actor re-claim leaves the prior builder untouched"
  ensure
    Current.reset
  end

  test "a plain build move records the assigned agent_slug as built_by (no --actor)" do
    # FIX (a): a bare `bin/task move <slug> building` defaults the event actor to
    # the session UUID (not a soul), so the actor path can't stamp. The task's
    # assigned agent_slug is the automatic, no-flag builder source — so
    # reviewer-select auto-excludes the builder WITHOUT the operator passing
    # --builder by hand every time.
    task = Task.create!(title: "assigned builder auto stamp", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build! # no Current actor — the bare-CLI build path

    assert_equal "carl", task.reload.devops_built_by,
      "the assigned agent is recorded as the builder automatically"
  end

  test "a session-id actor still falls back to the assigned agent_slug" do
    # The real bare-CLI move sets the actor to the session UUID. That's not a
    # soul, so it never stamps — but the assigned agent_slug now backstops it.
    Current.task_event_actor = "942a9824-375f-4d13-b60e-85be79ee9880"
    task = Task.create!(title: "session actor assignee stamp", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    assert_equal "carl", task.reload.devops_built_by,
      "a non-soul actor falls back to the assigned builder rather than stamping nothing"
  ensure
    Current.reset
  end

  test "a soul build actor wins over the assigned agent_slug" do
    # An explicit --actor <soul> attribution beats the agent_slug default.
    Current.task_event_actor = "shannon"
    task = Task.create!(title: "actor beats assignee task", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    assert_equal "shannon", task.reload.devops_built_by, "the explicit actor wins"
  ensure
    Current.reset
  end

  test "the agent_slug default never clobbers an existing built_by" do
    # Once stamped, a no-actor re-claim of an assigned task keeps the recorded
    # builder — the agent_slug default only fills a BLANK built_by, it never
    # overwrites (only an explicit --actor re-points on a re-claim).
    Current.task_event_actor = "shannon"
    task = Task.create!(title: "no clobber existing builder", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!
    assert_equal "shannon", task.reload.devops_built_by
    Current.reset

    task.update!(stage: "blocked")
    task.update!(stage: "building") # no actor; agent_slug is carl

    assert_equal "shannon", task.reload.devops_built_by,
      "the agent_slug default fills only a blank built_by, never overwrites"
  ensure
    Current.reset
  end

  test "an assigned build auto-excludes the builder from review end-to-end" do
    # The whole point of FIX (a): assign carl, do a plain build (no actor/flag),
    # and the reviewer pool excludes carl with no manual --builder.
    task = Task.create!(title: "assigned end to end exclude", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    decision = ReviewerSelector.explain(task.reload)
    assert_equal "carl", decision["builder"], "the assigned builder is read from devops.built_by"
    assert_equal "carl", decision["excluded_builder"]
    refute_includes decision["candidates"], "carl", "carl never reviews the PR carl built"
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

  # --- Position (event-driven rank: newest on top, 100-gap spacing) ---

  test "position is auto-set on create" do
    task = Task.create!(title: "Auto position test", stage: "designed")
    assert_not_nil task.position
  end

  test "a new task ranks above earlier tasks in its stage (top of column)" do
    existing = Task.where(stage: "designed").maximum(:position) || 0
    task = Task.create!(title: "fresh designed task here", stage: "designed")
    # max + 100 wins the `position DESC` sort, so a new card lands on top.
    assert_equal existing + 100, task.position
  end

  test "a stage move bumps the task to the top of the target stage" do
    task = tasks(:new_task)
    existing = Task.where(stage: "building").maximum(:position) || 0
    task.update!(stage: "building")
    assert_equal "building", task.stage
    assert_equal existing + 100, task.position
  end

  test "successive new tasks each rank above the previous (100-spaced)" do
    t1 = Task.create!(title: "first designed task here", stage: "designed")
    t2 = Task.create!(title: "second designed task here", stage: "designed")
    assert t2.position > t1.position
    assert_equal t1.position + 100, t2.position
  end

  test "ordered scope returns highest position first" do
    top = Task.create!(title: "top of designed column", stage: "designed")
    designed = Task.ordered.where(stage: "designed").to_a
    assert_equal top, designed.first, "the freshest (highest-position) task sorts first"
    positions = designed.map(&:position)
    assert_equal positions.sort.reverse, positions, "ordered is position DESC"
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

  # --- Build claim lease (V2) ---

  test "claim keys survive devops normalization (persist on the board)" do
    metadata = Task.normalize_devops_metadata(
      "claimed_session" => "sess-1",
      "claim_nonce" => "inst-A",
      "claim_expires_at" => "2026-06-23T12:02:00Z"
    )
    assert_equal "sess-1", metadata["claimed_session"]
    assert_equal "inst-A", metadata["claim_nonce"]
    assert_equal "2026-06-23T12:02:00Z", metadata["claim_expires_at"]
  end

  test "claim_live? and heartbeat age reflect a non-expired lease" do
    now = Time.utc(2026, 6, 23, 12, 0, 0)
    task = Task.create!(
      title: "Claimed build task",
      metadata: { "devops" => {
        "claimed_session" => "sess-1", "claim_nonce" => "inst-A",
        "claim_expires_at" => (now + 90).utc.iso8601
      } }
    )

    assert task.claim_live?(now: now)
    assert_equal "sess-1", task.claimed_session_id
    assert_equal "inst-A", task.devops_claim_nonce
    # 120s TTL, 90s of lease left ⇒ last heartbeat ~30s ago.
    assert_equal 30, task.claim_heartbeat_seconds_ago(now: now)
  end

  test "claim_live? is false once the lease has expired" do
    now = Time.utc(2026, 6, 23, 12, 0, 0)
    task = Task.create!(
      title: "Stale claim task",
      metadata: { "devops" => {
        "claimed_session" => "sess-1", "claim_nonce" => "inst-A",
        "claim_expires_at" => (now - 5).utc.iso8601
      } }
    )

    refute task.claim_live?(now: now)
  end

  test "an unclaimed task is not live" do
    task = Task.create!(title: "Unclaimed build task")
    refute task.claim_live?
    assert_nil task.claimed_session_id
    assert_nil task.claim_heartbeat_seconds_ago
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

  # --- App identity (status-line color) + agent persona ----------------------

  test "create stamps the app's status-line color from the first repository" do
    task = Task.create!(title: "App color stamp task",
                        metadata: { "devops" => { "repositories" => ["turf-monster"] } })
    assert_equal "#22C55E", task.devops["app_color"], "a Turf Monster task carries green"
  end

  test "app_color is re-stamped on update and follows a repository change" do
    task = Task.create!(title: "App color update task",
                        metadata: { "devops" => { "repositories" => ["turf-monster"] } })
    task.update!(metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    assert_equal "#B57EDC", task.reload.devops["app_color"], "the tint follows the new repo"
  end

  test "app_color is left unset for a repo with no App row" do
    task = Task.create!(title: "Unknown repo color task",
                        metadata: { "devops" => { "repositories" => ["mystery-app"] } })
    assert_nil task.devops["app_color"], "an unknown app → default tint at render time"
  end

  test "a persona makes the mascot the soul (glyph + tint), not a Pokemon" do
    seed_pokemon("snorlax", "pikachu")
    Agent.create!(name: "Jasper", slug: "jasper", status: "active",
                  metadata: { "emoji" => "🧪", "color" => "#9945FF" })
    task = Task.create!(title: "Act as Jasper task",
                        metadata: { "devops" => { "persona" => "jasper" } })
    assert_equal "Jasper", task.devops["mascot"], "the mascot becomes the soul"
    assert_equal "🧪", task.devops["mascot_emoji"]
    assert_equal "#9945FF", task.devops["mascot_color"]
    refute_includes %w[snorlax pikachu], task.devops["mascot"], "the Pokemon is not drawn over it"
  end

  test "an unknown persona falls through to the Pokemon path" do
    seed_pokemon("snorlax")
    task = Task.create!(title: "Unknown persona task",
                        metadata: { "devops" => { "persona" => "nobody" } })
    assert_equal "snorlax", task.devops["mascot"], "no such soul → keep the session Pokemon"
  end

  test "persona none reverts the mascot to the session Pokemon mid-task" do
    seed_pokemon("snorlax", "pikachu")
    Agent.create!(name: "Jasper", slug: "jasper", status: "active",
                  metadata: { "emoji" => "🧪", "color" => "#9945FF" })
    task = Task.create!(title: "Revert persona task",
                        metadata: { "devops" => { "persona" => "jasper" } })
    assert_equal "Jasper", task.devops["mascot"], "starts as the soul"

    # Simulate the CLI read-modify-write: the prior soul rides back with persona=none,
    # so the clear path must actively nil the stale mascot, not just drop the key.
    task.update!(metadata: { "devops" => { "mascot" => "Jasper", "persona" => "none" } })
    task.reload
    assert_includes %w[snorlax pikachu], task.devops["mascot"], "reverts to a Pokemon"
    assert_nil task.devops["persona"], "the persona key is dropped"
    assert_nil task.devops["mascot_emoji"], "the soul's glyph is cleared"
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

  test "submitted->reviewed records the same pair bin/reviewer-select would preview" do
    # Integration boundary for AC2: the recorder (stage_event_metadata ->
    # ReviewerSelector.select) writes the reviewers into the submitted->reviewed
    # TaskEvent, while bin/reviewer-select previews them via .decision/.explain —
    # two independent passes. With the per-task seeded tiebreak they must agree,
    # even on a genuine tie (no shape/risk/repo), so Avi never spawns a pair the
    # timeline then contradicts.
    task = Task.create!(title: "reviewer record boundary task", stage: "submitted")
    preview = ReviewerSelector.explain(task)["reviewers"].map { |r| r["slug"] }

    task.review! # submitted -> reviewed; the recorder writes the reviewers

    event = task.task_events.chronological.last
    assert_equal "reviewed", event.to_stage, "the recorded event is the submitted->reviewed transition"
    recorded = Task.normalize_reviewers(event.metadata["reviewers"]).map { |r| r["slug"] }
    assert_equal preview, recorded,
      "the recorded reviewers must match the CLI preview for the same task (no divergence)"
  end

  # --- Mascot backfill (for tasks created before the feature shipped) ---
  #
  # Backfill is global, so the loaded task fixtures are also live + mascotless and
  # get filled too. Tests assert on relative counts + the specific tasks they
  # create, and seed enough Pokémon that no draw falls back to a duplicate.

  def seed_backfill_deck(spare = 3)
    (Task.live.count + spare).times do |i|
      Pokemon.create!(dex: 700 + i, name: "Mon#{i}", slug: "mon-#{i}", generation: 1)
    end
  end

  test "backfill_mascots! fills every live mascotless task with distinct picks and returns the count" do
    a = Task.create!(title: "Backfill task one here")
    b = Task.create!(title: "Backfill task two here")
    [a, b].each { |t| t.update_column(:metadata, {}) }
    seed_backfill_deck

    blank_before = Task.live.count { |t| t.devops["mascot"].blank? }
    count = Task.backfill_mascots!

    assert_equal blank_before, count
    assert_equal 0, Task.live.count { |t| t.devops["mascot"].blank? }, "no live task left mascotless"
    assert a.reload.devops["mascot"].present?
    assert b.reload.devops["mascot"].present?
    assert_not_equal a.devops["mascot"], b.devops["mascot"], "live tasks get distinct mascots"
  end

  test "backfill_mascots! is idempotent — a second run assigns nothing" do
    task = Task.create!(title: "Idempotent backfill task here")
    task.update_column(:metadata, {})
    seed_backfill_deck

    Task.backfill_mascots!
    assert task.reload.devops["mascot"].present?
    assert_equal 0, Task.backfill_mascots!, "a second run assigns nothing"
  end

  test "backfill_mascots! leaves an existing mascot untouched" do
    seed_pokemon("snorlax")
    task = Task.create!(title: "Already has a mascot",
                        metadata: { "devops" => { "mascot" => "ditto" } })

    Task.backfill_mascots!

    assert_equal "ditto", task.reload.devops["mascot"]
  end

  test "backfill_mascots! skips terminal (shipped/archived) tasks" do
    seed_backfill_deck
    shipped = Task.create!(title: "Shipped terminal backfill task")
    shipped.update_columns(stage: "shipped", metadata: {})

    Task.backfill_mascots!

    assert_nil shipped.reload.devops["mascot"], "terminal tasks are not backfilled"
  end

  test "backfill_mascots! captures a failed row to ErrorLog and continues" do
    good = Task.create!(title: "Good backfill task here")
    bad  = Task.create!(title: "Bad backfill task here")
    good.update_column(:metadata, {})
    bad.update_columns(metadata: {}, priority: 99) # invalid priority → update! raises
    seed_backfill_deck
    errors_before = ErrorLog.count

    assert_nothing_raised { Task.backfill_mascots! }

    assert good.reload.devops["mascot"].present?, "the healthy task is still backfilled"
    assert_nil bad.reload.devops["mascot"], "the failing task is skipped, not aborted"
    assert_equal errors_before + 1, ErrorLog.count, "the failure is captured to ErrorLog"
    assert_equal bad.slug, ErrorLog.last.target_name
  end

  # --- per-session mascot -----------------------------------------------------

  test "tasks from the same session share one mascot" do
    Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", generation: 1)
    Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander", generation: 1)
    a = Task.create!(title: "session mascot a", metadata: { "devops" => { "session_id" => "sess-X" } })
    b = Task.create!(title: "session mascot b", metadata: { "devops" => { "session_id" => "sess-X" } })

    assert a.devops["mascot"].present?
    assert_equal a.devops["mascot"], b.devops["mascot"], "same session → same Pokémon"
  end

  test "a task picked up by a different session swaps its mascot on a build transition" do
    3.times { |i| Pokemon.create!(dex: i + 1, name: "Mon#{i}", slug: "mon#{i}", generation: 1) }
    t = Task.create!(title: "handoff new session task", stage: "building",
                     metadata: { "devops" => { "session_id" => "sess-A" } })
    first = t.devops["mascot"]
    assert first.present?

    # another agent claims it (new session) and makes a build-phase move
    t.update!(stage: "submitted", metadata: t.metadata.deep_merge("devops" => { "session_id" => "sess-B" }))

    assert_not_equal first, t.reload.devops["mascot"], "new session → new Pokémon"
  end

  test "a session-less task still gets a one-off mascot" do
    Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", generation: 1)
    assert Task.create!(title: "no session task").devops["mascot"].present?
  end

  test "resync_session_mascots! collapses a session's tasks onto one Pokemon" do
    3.times { |i| Pokemon.create!(dex: i + 1, name: "M#{i}", slug: "m#{i}", generation: 1) }
    a = Task.create!(title: "old session task a", metadata: { "devops" => { "session_id" => "S" } })
    b = Task.create!(title: "old session task b", metadata: { "devops" => { "session_id" => "S" } })
    # force the OLD per-task world: same session, DIFFERENT mascots, no session tag
    a.update_columns(metadata: { "devops" => { "session_id" => "S", "mascot" => "m0" } })
    b.update_columns(metadata: { "devops" => { "session_id" => "S", "mascot" => "m1" } })

    Task.resync_session_mascots!

    assert_equal a.reload.devops["mascot"], b.reload.devops["mascot"], "one mascot per session"
  end

  test "the same session keeps its mascot across a build transition" do
    # Regression: mascot_session was stripped by normalize_devops_metadata, so every
    # build transition re-rolled the Pokémon (designed→building showed a different one).
    3.times { |i| Pokemon.create!(dex: i + 1, name: "P#{i}", slug: "p#{i}", generation: 1) }
    t = Task.create!(title: "stable session mascot task",
                     metadata: { "devops" => { "session_id" => "sess-stable" } })
    first = t.devops["mascot"]
    assert first.present?
    assert_equal "sess-stable", t.devops["mascot_session"], "mascot_session must survive the save"

    t.update!(stage: "building") # same session, build transition — must NOT re-roll

    assert_equal first, t.reload.devops["mascot"], "same session keeps one Pokémon across designed→building"
  end

  test "normalize_devops_metadata keeps the mascot_session tag" do
    # The actual stripping point (the API path normalizes; the model alone does not):
    # mascot_session was dropped here, so the saved task lost it and every transition
    # re-rolled. It must survive normalization.
    result = Task.normalize_devops_metadata("mascot" => "graveler", "mascot_session" => "sess-1")

    assert_equal "graveler", result["mascot"]
    assert_equal "sess-1", result["mascot_session"], "mascot_session must survive normalization"
  end

  # --- Auto-derived actual_size (the measured leg of the size trio) -----------

  # Stamp `count` measured tokens onto a task as a single TaskEvent (split across
  # in/out so tokens_total sums them). update_column avoids re-triggering callbacks.
  def stamp_tokens(task, count)
    task.task_events.create!(to_stage: task.stage, occurred_at: Time.current,
                             tokens_in: count / 2, tokens_out: count - (count / 2))
  end

  test "derive_actual_size maps total tokens through the threshold map" do
    cases = {
      500_000     => "small",   # < 1M
      999_999     => "small",   # just under the small ceiling
      1_000_000   => "medium",  # the small ceiling is EXCLUSIVE → medium
      4_999_999   => "medium",  # just under the medium ceiling
      5_000_000   => "large",   # the medium ceiling is EXCLUSIVE → large
      14_999_999  => "large",   # just under the large ceiling
      15_000_000  => "xl",      # the large ceiling is EXCLUSIVE → xl
      40_000_000  => "xl"       # well into xl
    }
    cases.each do |tokens, expected|
      task = Task.create!(title: "size boundary task #{tokens}", stage: "building")
      stamp_tokens(task, tokens)
      assert_equal expected, task.derive_actual_size, "#{tokens} tokens → #{expected}"
    end
  end

  test "derive_actual_size is nil with no measured usage (honest, not small)" do
    task = Task.create!(title: "no usage size task", stage: "building")
    # The genesis event carries no tokens, so the measured total is zero.
    assert_equal 0, task.measured_tokens_total
    assert_nil task.derive_actual_size, "zero measured tokens can't be sized → nil, never a false 'small'"
  end

  test "measured_tokens_total sums tokens_total across all events" do
    task = Task.create!(title: "token sum task", stage: "building")
    stamp_tokens(task, 2_000_000)
    stamp_tokens(task, 3_000_000)
    assert_equal 5_000_000, task.measured_tokens_total
  end

  # --- total_cost (the release-notes card $cost) ------------------------------

  test "total_cost sums the cost across all events, ignoring nil costs" do
    task = Task.create!(title: "cost sum task here", stage: "building")
    # The genesis event carries no cost (nil) — SQL SUM must skip it.
    task.task_events.create!(to_stage: task.stage, occurred_at: Time.current, cost: BigDecimal("0.50"))
    task.task_events.create!(to_stage: task.stage, occurred_at: Time.current, cost: BigDecimal("0.37"))

    assert_equal BigDecimal("0.87"), task.total_cost
  end

  test "total_cost is zero for a task with no priced events" do
    task = Task.create!(title: "zero cost task here", stage: "building")
    # Only the (cost-less) genesis event exists.
    assert task.total_cost.zero?, "an unpriced task totals zero, not nil"
  end

  test "shipping auto-derives actual_size from measured usage when blank" do
    task = Task.create!(title: "ship derives size task", stage: "assembled")
    stamp_tokens(task, 6_000_000) # → large (≥5M, <15M)
    assert_nil task.actual_size

    task.ship!

    assert_equal "large", task.reload.actual_size, "ship stamps the measured size onto a blank actual_size"
  end

  test "shipping never clobbers a manually set actual_size" do
    task = Task.create!(title: "manual size wins task", stage: "assembled", actual_size: "small")
    stamp_tokens(task, 40_000_000) # would derive xl

    task.ship!

    assert_equal "small", task.reload.actual_size, "a manual size is never overwritten by the auto-derivation"
  end

  test "shipping with no measured usage leaves actual_size blank" do
    task = Task.create!(title: "ship no usage task", stage: "assembled")

    task.ship!

    assert_nil task.reload.actual_size, "no usage → no size; the ship still completes"
  end

  test "actual_size is only derived at shipped, not earlier stages" do
    task = Task.create!(title: "size only at ship task", stage: "building")
    stamp_tokens(task, 6_000_000)

    task.update!(stage: "submitted")

    assert_nil task.reload.actual_size, "a non-ship transition must not stamp actual_size"
  end
end
