require "test_helper"
require Rails.root.join("db/migrate/20260924210000_rename_alex_soul_to_xan.rb").to_s

# [unit] RenameAlexSoulToXan repoints EVERY stored `alex` soul value to `xan`,
# counts each surface before and after, runs a second time without changing a
# row, and reverses. The rows below are planted with the callback-free writers
# (update_columns / insert_all / the migration's own shims) because the live
# models now CANONICALIZE `alex` on write — the only way to build a row the way a
# deployed database still holds it is to bypass them, exactly as the migration does.
class RenameAlexSoulToXanMigrationTest < ActiveSupport::TestCase
  M = RenameAlexSoulToXan

  setup do
    # The fixture roster ships xan; plant the pre-rename Agent row beside it so
    # the duplicate-row retirement has something to retire.
    Agent.where(slug: %w[alex]).delete_all
    @now = Time.current
    plant_alex_rows
  end

  def migrate(direction) = capture_io { M.new.public_send(direction) }

  # One `alex` on every surface the migration knows, plus a `xan` sibling on the
  # unique-keyed ones where the guard has to hold.
  def plant_alex_rows
    Agent.insert_all([{ name: "Alex (legacy row)", slug: "alex", created_at: @now, updated_at: @now }])

    @task = Task.create!(title: "migration sample task row", stage: "submitted",
                         metadata: { "devops" => { "shape" => "docs" } })
    @task.update_columns(
      agent_slug: "alex", blocked_by: "alex",
      metadata: {
        "devops" => { "shape" => "docs", "built_by" => "alex", "persona" => "alex",
                      "approval_requested_by" => "alex", "builders" => %w[steffon alex],
                      "fix_forward" => %w[alex] },
        "reviewers" => [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "alex", "weight" => "light" }]
      }
    )

    # Task.create! above wrote a genesis TaskEvent of its own, so keep the ids
    # of the rows planted here rather than reading `.first` off the task.
    @event_id = M::Ev.insert_all([{ task_slug: @task.slug, to_stage: "reviewed", actor: "alex", occurred_at: @now,
                                    metadata: { "reviewers" => [{ "slug" => "alex", "weight" => "light" }] },
                                    created_at: @now, updated_at: @now }]).first["id"]
    @activity_id = M::Ac.insert_all([{ agent_slug: "alex", activity_type: "comment", task_slug: @task.slug,
                                       metadata: { "reporter" => "alex" }, created_at: @now, updated_at: @now }]).first["id"]

    @span = AgentActivity.create!(session_id: "mig-sess", category: "Explore", reason_slug: "sample",
                                  opened_at: @now, closed_at: @now, outcome_slug: "done")
    @span.update_columns(agent: "alex", supervisor_agent: "alex")
    ActionGrade.insert_all([{ agent_activity_id: @span.id, grader: "alex", disposition: "good",
                              slug: "a lesson under the old slug", created_at: @now, updated_at: @now }])
    # A second span that ALREADY holds a xan grade beside its alex one — the
    # unique-key guard must leave that alex row alone rather than collide.
    @held = AgentActivity.create!(session_id: "mig-sess", category: "Verify", reason_slug: "held",
                                  opened_at: @now, closed_at: @now, outcome_slug: "done")
    ActionGrade.insert_all([
      { agent_activity_id: @held.id, grader: "alex", disposition: "good", slug: "old", created_at: @now, updated_at: @now },
      { agent_activity_id: @held.id, grader: "xan", disposition: "not", slug: "new", created_at: @now, updated_at: @now }
    ])

    TaskReviewClaim.insert_all([{ task_slug: @task.slug, holder_agent: "alex", created_at: @now, updated_at: @now }])
    ReviewPendingAction.insert_all([{ task_slug: @task.slug, repo: "mcritchie-studio", head_sha: "abc1234", pr_number: 1,
                                      verdict: "merge", authorized_by: "alex", expires_at: @now + 1.hour,
                                      created_at: @now, updated_at: @now }])
    DevopsShift.insert_all([{ lane: "alex", created_at: @now, updated_at: @now }])
    GateRun.insert_all([{ subject_type: "task", subject_slug: @task.slug, key: "g2b_light", attempt: 1,
                          actor: "alex", started_at: @now, created_at: @now, updated_at: @now }])
    ReleaseEvent.insert_all([{ release_slug: "rel-sample", step: "ship_gate", status: "started", actor: "alex",
                               occurred_at: @now, created_at: @now, updated_at: @now }])
    Release.insert_all([{ slug: "rel-sample", confirmed_by: "alex", created_at: @now, updated_at: @now }])
    DeskRecord.insert_all([{ worktree_path: "/tmp/desk-sample", actor: "alex", created_at: @now, updated_at: @now }])
    Usage.insert_all([{ agent_slug: "alex", period_date: Date.current, period_type: "daily", model: "m",
                        created_at: @now, updated_at: @now }])
    SkillAssignment.insert_all([{ agent_slug: "alex", skill_slug: "orchestration", created_at: @now, updated_at: @now }])
  end

  def surfaces_holding(value) = M.counts(value).select { |_, n| n.positive? }

  test "counts every surface before, repoints it, and counts zero after" do
    before = surfaces_holding("alex")
    expected = {
      "activities.agent_slug" => 1, "usages.agent_slug" => 1, "skill_assignments.agent_slug" => 1,
      "tasks.agent_slug" => 1, "tasks.blocked_by" => 1, "task_events.actor" => 1,
      "action_grades.grader" => 2, "task_review_claims.holder_agent" => 1,
      "review_pending_actions.authorized_by" => 1, "agent_activities.agent" => 1,
      "agent_activities.supervisor_agent" => 1, "devops_shifts.lane" => 1, "gate_runs.actor" => 1,
      "release_events.actor" => 1, "releases.confirmed_by" => 1, "desk_records.actor" => 1, "agents.slug" => 1,
      "tasks.metadata.devops.built_by" => 1, "tasks.metadata.devops.persona" => 1,
      "tasks.metadata.devops.approval_requested_by" => 1, "tasks.metadata.devops.builders" => 1,
      "tasks.metadata.devops.fix_forward" => 1, "tasks.metadata.reviewers" => 1,
      "task_events.metadata.reviewers" => 1, "activities.metadata.reporter" => 1
    }
    assert_equal expected, before.slice(*expected.keys), "every surface holds the planted alex row"
    assert_equal expected.keys.sort, before.keys.sort, "and no surface the migration knows was left unplanted"
    # The fixtures already seed the seat under `xan` (an Agent row, a task
    # assigned to it), so the target side is read as a DELTA over that floor.
    xan_before = M.counts("xan")

    migrate(:up)

    after = surfaces_holding("alex")
    assert_equal({ "action_grades.grader" => 1 }, after,
                 "only the grade whose span already holds a xan grade is HELD; every other surface is empty")
    assert_equal 1, ActionGrade.where(agent_activity_id: @held.id, grader: "alex").count
    assert_equal 1, ActionGrade.where(agent_activity_id: @held.id, grader: "xan").count

    xan_after = M.counts("xan")
    landed = expected.to_h { |surface, n| [surface, xan_after.fetch(surface) - xan_before.fetch(surface)] }
    # Every alex row landed on xan except the one HELD grade (2 planted, 1
    # moved) and the Agent row itself: xan is already seeded, so the planted
    # alex row is RETIRED rather than renamed (asserted by identity below).
    assert_equal expected.merge("action_grades.grader" => 1, "agents.slug" => 0), landed,
                 "each surface gains exactly the rows that left alex"
  end

  test "the JSON shapes are rewritten in place and nothing beside them moves" do
    migrate(:up)

    meta = @task.reload.metadata
    assert_equal "xan", meta.dig("devops", "built_by")
    assert_equal "xan", meta.dig("devops", "persona")
    assert_equal "xan", meta.dig("devops", "approval_requested_by")
    assert_equal %w[steffon xan], meta.dig("devops", "builders"), "the other author keeps its place"
    assert_equal %w[xan], meta.dig("devops", "fix_forward")
    assert_equal "docs", meta.dig("devops", "shape"), "an unrelated key is untouched"
    assert_equal [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "xan", "weight" => "light" }], meta["reviewers"]
    assert_equal [{ "slug" => "xan", "weight" => "light" }], M::Ev.find(@event_id).metadata["reviewers"]
    assert_equal({ "reporter" => "xan" }, M::Ac.find(@activity_id).metadata)
    assert_equal "xan", @task.agent_slug
    assert_equal "xan", @task.blocked_by
  end

  test "the duplicate Agent row is retired by SQL and its children survive" do
    xan = Agent.find_by!(slug: "xan")
    assert Agent.exists?(slug: "alex"), "precondition: both rows present"
    activities_before = Activity.count

    migrate(:up)

    refute Agent.exists?(slug: "alex"), "the empty shell is gone"
    assert_equal xan.id, Agent.find_by!(slug: "xan").id, "the seeded row is the survivor"
    assert_equal activities_before, Activity.count, "a destroy would have cascaded; the SQL delete did not"
    assert_equal 1, Activity.where(agent_slug: "xan", task_slug: @task.slug).count
  end

  test "running up twice changes nothing the second time" do
    migrate(:up)
    snapshot = -> { [surfaces_holding("alex"), surfaces_holding("xan"), @task.reload.metadata, Agent.pluck(:slug).sort] }
    first = snapshot.call

    migrate(:up)

    assert_equal first, snapshot.call, "the second run is a no-op — every write is WHERE value = 'alex'"
  end

  test "down reverses the repoint" do
    migrate(:up)
    migrate(:down)

    # `down` is the honest reverse of a rename: it moves every xan value,
    # including the fixture task seeded under the new slug — so assert the
    # planted rows by identity, not by a count that also sees the fixture.
    assert_equal "alex", @task.reload.agent_slug
    assert_equal "alex", @task.blocked_by
    assert_equal "alex", M::Ev.find(@event_id).actor
    assert_equal "alex", @task.metadata.dig("devops", "built_by")
    assert_equal %w[steffon alex], @task.metadata.dig("devops", "builders")
    assert_equal 1, surfaces_holding("alex")["agents.slug"], "the seat is back under its old slug"
    assert_empty surfaces_holding("xan").except("action_grades.grader"),
                 "nothing but the guarded grade pair still says xan"
  end

  test "up on a database with no alex rows is a clean no-op" do
    migrate(:up)
    assert_equal({ "action_grades.grader" => 1 }, surfaces_holding("alex"))
    counts_after_first = M.counts("xan")

    migrate(:up)

    assert_equal counts_after_first, M.counts("xan")
  end
end
