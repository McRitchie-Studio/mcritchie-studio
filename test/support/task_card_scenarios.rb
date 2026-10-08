# frozen_string_literal: true

# One board card per state the card branches on, built from real rows at a fixed
# clock. Each scenario answers { task:, crew_board:, given: }: `given` holds the
# inputs a board hands in for that state; every other input is the single-card
# read. test/components/task_card_characterisation_test.rb renders each one and
# compares it with its snapshot under test/fixtures/files/task_card.
module TaskCardScenarios
  NOW = Time.utc(2026, 10, 1, 18, 0, 0)
  BOUNCE_AT = NOW - 3.hours

  TypeColor = Struct.new(:key, :color, :rank, :emoji, keyword_init: true)
  TYPE_ENUMERALS = {
    "fire" => TypeColor.new(key: "fire", color: "#EE8130", rank: 900, emoji: "🔥"),
    "flying" => TypeColor.new(key: "flying", color: "#A98FF3", rank: 200, emoji: "💨"),
    "water" => TypeColor.new(key: "water", color: "#6390F0", rank: 10, emoji: "💧")
  }.freeze

  NAMES = %w[
    designed designed_planning_badges
    building_unclaimed building_claimed building_claim_quiet building_ci_meter
    blocked_rework blocked_dependency_escalated
    waiting_approval waiting_approval_no_local_url
    resubmission_unmoved resubmission_moved
    submitted submitted_under_review submitted_review_over_approval
    submitted_cleared_block submitted_blocked
    reviewed reviewed_held_from_release reviewed_blocked
    assembled shipped archived activity_notes
    reviewed_with_crew submitted_ci_failed submitted_ci_green
    blocked_no_summary waiting_approval_lapsed assembled_colour_fallback
  ].freeze

  def task_card_scenario(name)
    send("scenario_#{name}")
  end

  private

  def scenario_task(title, stage:, devops: {}, **attrs)
    Task.create!(title: title, stage: stage, metadata: { "devops" => devops }, **attrs)
  end

  def single_type_mascot
    Pokemon.find_or_create_by!(slug: "totodile") do |pokemon|
      pokemon.assign_attributes(dex: 158, name: "Totodile", types: %w[water], primary_type: "water", generation: 2)
    end
  end

  def dual_type_mascot
    Pokemon.find_or_create_by!(slug: "charizard") do |pokemon|
      pokemon.assign_attributes(dex: 6, name: "Charizard", types: %w[fire flying], primary_type: "fire", generation: 1)
    end
  end

  def with_mascot(mascot)
    { mascot: mascot, type_enumerals: TYPE_ENUMERALS }
  end

  def no_mascot
    { mascot: nil, type_enumerals: nil }
  end

  def block_note(task, summary:, kind:, by: "carl")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", agent_slug: by,
                     description: "#{summary}. The full note lives on the task page.",
                     metadata: { "summary" => summary, "kind" => kind })
  end

  def claimed(task, genesis_age: 6.hours)
    task.update_columns(metadata: { "devops" => ClaimLease.renewed(session: "sess-1", nonce: "inst-A", now: NOW) })
    TaskEvent.where(task_slug: task.slug).update_all(occurred_at: NOW - genesis_age)
    task
  end

  def bounced(title, head_now: nil)
    task = scenario_task(title, stage: "building", devops: {
      "branch" => "feat/#{title.parameterize}", "repositories" => ["mcritchie-studio"],
      "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/513"
    })
    ci_run(task, sha: "029a945b", at: BOUNCE_AT - 10.minutes)
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                     description: "The sibling's both-copies claims survive the change.",
                     metadata: { "kind" => "rework", "summary" => "Sibling both-copies claims survive" },
                     created_at: BOUNCE_AT, updated_at: BOUNCE_AT)
    ci_run(task, sha: head_now, at: BOUNCE_AT + 20.minutes) if head_now
    task
  end

  def ci_run(task, sha:, at:)
    GithubWorkflowRun.create!(
      repo: "McRitchie-Studio/mcritchie-studio", workflow_name: GithubWorkflowRun::CI_WORKFLOW,
      run_id: sha.to_i(16), status: "completed", conclusion: "success",
      head_branch: task.devops_field("branch"), head_sha: sha, run_started_at: at, created_at: at
    )
  end

  def scenario_designed
    { task: scenario_task("Snapshot designed card", stage: "designed"), crew_board: :build, given: no_mascot }
  end

  def scenario_designed_planning_badges
    task = scenario_task("Snapshot planning badges card with a title long enough to overflow the column",
                         stage: "designed", po_size: "xl", requires_migration: true, epic_slug: "devops-v3",
                         devops: { "kind" => "bug", "shape" => "library", "requires_release_conductor" => true,
                                   "repositories" => %w[mcritchie-studio turf-monster] })
    { task: task, crew_board: :build, given: no_mascot }
  end

  def scenario_building_unclaimed
    task = scenario_task("Snapshot building unclaimed card", stage: "building", devops: { "kind" => "docs" })
    { task: task, crew_board: :build, given: with_mascot(single_type_mascot) }
  end

  def scenario_building_claimed
    task = claimed(scenario_task("Snapshot building claimed card", stage: "building"))
    GateRun.create!(subject_type: "task", subject_slug: task.slug, key: "g1_cert", attempt: 1,
                    started_at: NOW - 4.minutes, created_at: NOW - 4.minutes, updated_at: NOW - 4.minutes)
    { task: task, crew_board: :build, given: with_mascot(single_type_mascot) }
  end

  def scenario_building_claim_quiet
    silence = ClaimLease::PROGRESS_QUIET_SECONDS + 30.minutes
    task = claimed(scenario_task("Snapshot building quiet claim card", stage: "building"), genesis_age: silence + 1.hour)
    TaskEvent.create!(task_slug: task.slug, kind: TaskEvent::CHECKPOINT, occurred_at: NOW - silence,
                      from_stage: "building", to_stage: "cert", metadata: { "status" => "started" })
    { task: task, crew_board: :build, given: no_mascot }
  end

  def scenario_building_ci_meter
    task = scenario_task("Snapshot building CI meter card", stage: "building",
                         devops: { "pr_url" => "https://github.com/acme/app/pull/11" })
    progress = Ci::CheckProgress.new(passed: 3, failed: 0, pending: 2, sha: "building-head-sha")
    { task: task, crew_board: :build, given: no_mascot.merge(ci_progress: progress) }
  end

  def scenario_blocked_rework
    task = scenario_task("Snapshot blocked rework card", stage: "building")
    task.block!(by: "carl", kind: "rework")
    block_note(task, summary: "Spacing off on the chip", kind: "rework")
    { task: task, crew_board: :build, given: with_mascot(single_type_mascot) }
  end

  def scenario_blocked_dependency_escalated
    task = scenario_task("Snapshot blocked escalated card", stage: "building")
    task.block!(by: "avi", kind: "dependency")
    block_note(task, summary: "Escalated: which default wins", kind: "dependency", by: "avi")
    { task: task, crew_board: :deploy, given: no_mascot }
  end

  def scenario_waiting_approval
    task = scenario_task("Snapshot waiting approval card", stage: "building", epic_slug: "devops-v3",
                         devops: { "approval_status" => "waiting", "local_url" => "http://localhost:3011/tasks" })
    { task: task, crew_board: :build, given: with_mascot(single_type_mascot) }
  end

  def scenario_waiting_approval_no_local_url
    task = scenario_task("Snapshot waiting approval no url card", stage: "building",
                         devops: { "approval_status" => "waiting" })
    { task: task, crew_board: :build, given: no_mascot }
  end

  def scenario_resubmission_unmoved
    { task: bounced("Snapshot resubmission unmoved card"), crew_board: :build, given: no_mascot }
  end

  def scenario_resubmission_moved
    { task: bounced("Snapshot resubmission moved card", head_now: "bbbb2222"), crew_board: :build, given: no_mascot }
  end

  def scenario_submitted
    task = scenario_task("Snapshot submitted card", stage: "submitted",
                         devops: { "pr_url" => "https://github.com/acme/app/pull/42" })
    { task: task, crew_board: :deploy, given: with_mascot(single_type_mascot).merge(ci_progress: nil) }
  end

  def scenario_submitted_under_review
    task = scenario_task("Snapshot submitted under review card", stage: "submitted",
                         devops: { "pr_url" => "https://github.com/acme/app/pull/43" })
    task.record_intent_event(to_stage: "reviewed", reviewers: [{ "slug" => "carl", "weight" => "primary" }])
    { task: task, crew_board: :deploy,
      given: with_mascot(dual_type_mascot).merge(ci_progress: nil, review_in_progress: true) }
  end

  def scenario_submitted_review_over_approval
    task = scenario_task("Snapshot review over approval card", stage: "building",
                         devops: { "approval_status" => "waiting", "local_url" => "http://localhost:3011/tasks" })
    task.submit!
    { task: task, crew_board: :deploy,
      given: with_mascot(single_type_mascot).merge(ci_progress: nil, review_in_progress: true) }
  end

  def scenario_submitted_cleared_block
    task = scenario_task("Snapshot cleared block card", stage: "submitted")
    { task: task, crew_board: :deploy,
      given: no_mascot.merge(ci_progress: nil, unresolved_feedback: nil, ever_blocked: true) }
  end

  def scenario_submitted_blocked
    task = scenario_task("Snapshot submitted blocked card", stage: "submitted")
    block_note(task, summary: "Please fix the empty state", kind: "rework")
    { task: task, crew_board: :deploy, given: no_mascot.merge(ci_progress: nil) }
  end

  def scenario_reviewed
    task = scenario_task("Snapshot reviewed card", stage: "building")
    task.submit!
    task.review!
    { task: task, crew_board: :deploy, given: with_mascot(single_type_mascot) }
  end

  def scenario_reviewed_held_from_release
    task = scenario_task("Snapshot reviewed held card", stage: "reviewed", devops: {
      "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/6", "included_in_release" => "false"
    })
    { task: task, crew_board: :deploy, given: no_mascot }
  end

  def scenario_reviewed_blocked
    task = scenario_task("Snapshot reviewed blocked card", stage: "reviewed")
    block_note(task, summary: "Regression on the deploy board", kind: "rework", by: "avi")
    { task: task, crew_board: :deploy, given: with_mascot(single_type_mascot) }
  end

  def scenario_assembled
    task = scenario_task("Snapshot assembled card", stage: "assembled")
    { task: task, crew_board: :deploy, given: with_mascot(dual_type_mascot) }
  end

  def scenario_shipped
    task = scenario_task("Snapshot shipped card", stage: "shipped", devops: {
      "qa_url" => "https://qa.example.test/tasks", "production_url" => "https://example.test/tasks"
    })
    { task: task, crew_board: :deploy, given: with_mascot(single_type_mascot) }
  end

  def scenario_archived
    { task: scenario_task("Snapshot archived card", stage: "archived"), crew_board: :deploy, given: no_mascot }
  end

  def scenario_activity_notes
    task = scenario_task("Snapshot activity notes card", stage: "designed")
    Activity.create!(task_slug: task.slug, activity_type: "comment", agent_slug: "carl", description: "First note.")
    latest = Activity.create!(task_slug: task.slug, activity_type: "clarification", agent_slug: "avi",
                              description: "Which default wins when both flags are set on the same task?")
    { task: task, crew_board: :build, given: no_mascot.merge(latest_activity: latest, activity_count: 2) }
  end

  # An assigned task that walked to reviewed under two reviewers: data-agent, the
  # filter's argument and the crew row all carry a soul.
  def scenario_reviewed_with_crew
    task = scenario_task("Snapshot reviewed with crew card", stage: "building", agent_slug: "pokemon")
    task.submit!
    task.record_intent_event(to_stage: "reviewed", reviewers: [{ "slug" => "carl", "weight" => "primary" },
                                                              { "slug" => "avi", "weight" => "light" }])
    task.review!
    { task: task, crew_board: :deploy, given: with_mascot(single_type_mascot) }
  end

  def scenario_submitted_ci_failed
    task = scenario_task("Snapshot submitted CI failed card", stage: "submitted",
                         devops: { "pr_url" => "https://github.com/acme/app/pull/44" })
    progress = Ci::CheckProgress.new(passed: 3, failed: 2, pending: 0, sha: "failed-head-sha")
    { task: task, crew_board: :deploy, given: no_mascot.merge(ci_progress: progress) }
  end

  def scenario_submitted_ci_green
    task = scenario_task("Snapshot submitted CI green card", stage: "submitted",
                         devops: { "pr_url" => "https://github.com/acme/app/pull/45" })
    progress = Ci::CheckProgress.new(passed: 5, failed: 0, pending: 0, sha: "green-head-sha")
    { task: task, crew_board: :deploy, given: no_mascot.merge(ci_progress: progress) }
  end

  # A block whose note carries no summary: the bar falls back to the note itself.
  def scenario_blocked_no_summary
    task = scenario_task("Snapshot blocked no summary card", stage: "building")
    task.block!(by: "carl", kind: "rework")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", agent_slug: "carl",
                     description: "The empty state shows <b>raw</b> markup & \"quotes\" on a narrow column.")
    { task: task, crew_board: :build, given: no_mascot }
  end

  # An approval request whose window has run out: the chip reads lapsed.
  def scenario_waiting_approval_lapsed
    task = scenario_task("Snapshot waiting approval lapsed card", stage: "building",
                         devops: { "approval_status" => "waiting", "approval_requested_at" => (NOW - 3.hours).iso8601,
                                   "local_url" => "http://localhost:3011/tasks" })
    { task: task, crew_board: :build, given: no_mascot }
  end

  # No mascot row: the glow takes the colour stamped on the task.
  def scenario_assembled_colour_fallback
    task = scenario_task("Snapshot assembled colour fallback card", stage: "assembled",
                         devops: { "mascot_color" => "#12ab34" })
    { task: task, crew_board: :deploy, given: no_mascot }
  end
end
