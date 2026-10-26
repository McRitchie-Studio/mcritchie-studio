require "test_helper"
require Rails.root.join("db/migrate/20261018180000_rename_xan_soul_to_ray.rb").to_s

# [unit] RenameXanSoulToRay repoints EVERY stored `xan` soul value to `ray`,
# counts each surface before and after, runs a second time without changing a
# row, and reverses. The rows are planted through the migration's own schema
# shims (insert_all / update_columns) because the live models now CANONICALIZE
# `xan` on write — the only way to build a row the way a deployed database still
# holds it is to bypass them, exactly as the migration does.
class RenameXanSoulToRayMigrationTest < ActiveSupport::TestCase
  M = RenameXanSoulToRay

  # The world this migration ran in (2026-10-18): the seat seeded under `ray`.
  # The fixtures seed it under `alex` since RenameRaySoulToAlex, so the `ray` row
  # this migration's target side reads is planted here, as the fixtures once did.
  setup do
    Agent.where(slug: "xan").delete_all
    @now = Time.current
    ins("agents", name: "Ritch", slug: "ray", avatar: "/agents/ray.webp") unless Agent.exists?(slug: "ray")
    TaskGrade.connection.change_column_default(:task_grades, :grader, "ray")
    plant_xan_rows
  end

  def migrate(direction) = capture_io { M.new.public_send(direction) }

  def ins(table, row)
    shim = M.shim(table)
    stamps = { created_at: @now, updated_at: @now }.select { |col, _| shim.column_names.include?(col.to_s) }
    shim.insert_all([stamps.merge(row)]).first["id"]
  end

  # One `xan` on every surface the migration knows, plus a `ray` sibling on the
  # unique-keyed ones where the guard has to hold.
  def plant_xan_rows
    ins("agents", name: "Ray (legacy row)", slug: "xan", avatar: "/agents/xan.webp")

    @task = Task.create!(title: "migration sample task row", stage: "submitted",
                         metadata: { "devops" => { "shape" => "docs" } })
    @task.update_columns(
      agent_slug: "xan", blocked_by: "xan",
      metadata: {
        "devops" => { "shape" => "docs", "built_by" => "xan", "persona" => "xan",
                      "approval_requested_by" => "xan", "builders" => %w[steffon xan],
                      "fix_forward" => %w[xan] },
        "reviewers" => [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "xan", "weight" => "light" }]
      }
    )

    @event_id = ins("task_events", task_slug: @task.slug, to_stage: "reviewed", actor: "xan", occurred_at: @now,
                                   metadata: { "reviewers" => [{ "slug" => "xan", "weight" => "light" }] })
    @activity_id = ins("activities", agent_slug: "xan", activity_type: "comment", task_slug: @task.slug,
                                     metadata: { "reporter" => "xan", "blocked_by" => "xan" })

    @span = ins("agent_activities", session_id: "mig-sess", category: "Explore", reason_slug: "sample",
                                    opened_at: @now, agent: "xan", supervisor_agent: "xan")
    ins("action_grades", agent_activity_id: @span, grader: "xan", disposition: "good", slug: "a lesson under the old slug")
    # A second span that ALREADY holds a ray grade beside its xan one — the
    # unique-key guard must leave that xan row alone rather than collide.
    @held = ins("agent_activities", session_id: "mig-sess", category: "Verify", reason_slug: "held", opened_at: @now)
    ins("action_grades", agent_activity_id: @held, grader: "xan", disposition: "good", slug: "old")
    ins("action_grades", agent_activity_id: @held, grader: "ray", disposition: "not", slug: "new")

    ins("task_grades", task_slug: @task.slug, grader: "xan", verdict: "clean", graded_at: @now)
    ins("task_review_claims", task_slug: @task.slug, holder_agent: "xan")
    ins("review_pending_actions", task_slug: @task.slug, repo: "mcritchie-studio", head_sha: "abc1234", pr_number: 1,
                                  verdict: "merge", authorized_by: "xan", expires_at: @now + 1.hour)
    ins("devops_shifts", lane: "xan")
    ins("gate_runs", subject_type: "task", subject_slug: @task.slug, key: "g2b_light", attempt: 1,
                     actor: "xan", started_at: @now)
    @release_id = ins("releases", slug: "rel-sample", confirmed_by: "xan",
                                  duration_metrics: { "tasks" => [{ "stages" => { "building" => { "actor" => "xan" } } }],
                                                      "release_steps" => { "ship_gate" => { "start_event" => { "actor" => "xan" } } },
                                                      "note" => "xan" })
    ins("release_events", release_slug: "rel-sample", step: "ship_gate", status: "started", actor: "xan", occurred_at: @now)
    ins("release_conductor_claims", release_slug: "rel-sample", role: "conductor", holder_soul: "xan")
    ins("desk_records", worktree_path: "/tmp/desk-sample", actor: "xan")
    ins("usages", agent_slug: "xan", period_date: Date.current, period_type: "daily", model: "m")
    ins("skill_assignments", agent_slug: "xan", skill_slug: "ruby-dev")

    @message_id = ins("agent_messages", channel: "web", channel_ref: "build:1", external_id: "mig-1",
                                        thread_key: "web:build:1", soul_slug: "xan")
    @message_event_id = ins("agent_message_events", agent_message_id: @message_id, kind: "claimed", actor: "xan",
                                                    detail: { "soul" => "xan", "worker" => "d1" })
    ins("agent_proposals", capability: "c", channel: "web", channel_ref: "build:1", expires_at: @now + 1.hour,
                           kind: "ask", soul_slug: "xan", thread_key: "web:build:1")
    person = ins("agent_people", display_name: "Sample Person")
    ins("agent_person_notes", agent_person_id: person, body: "likes ray", fingerprint: "fp-1", noted_at: @now, soul_slug: "xan")
    ins("agent_sessions", slug: "sess-mig-0001", soul: "xan", tier: "admin", issued_by: "operator_grant",
                          issued_at: @now, expires_at: @now + 1.hour)
    ins("agent_login_requests", slug: "alr-mig-0001", soul: "xan", harness_session_id: "h-1", collect_digest: "c",
                                phrase_digest: "p", requested_at: @now)
    @channel_id = ins("discord_channels", external_id: "c-1", guild_external_id: "g-1", kind: "text", name: "desk",
                                          postable_souls: %w[avi xan])
    @dispatcher_id = ins("agent_dispatchers", worker_id: "d-mig", last_seen_at: @now, souls: %w[avi xan client_cto])
  end

  def surfaces_holding(value) = M.counts(value).select { |_, n| n.positive? }

  EXPECTED = {
    "activities.agent_slug" => 1, "usages.agent_slug" => 1, "skill_assignments.agent_slug" => 1,
    "tasks.agent_slug" => 1, "tasks.blocked_by" => 1, "task_events.actor" => 1,
    "action_grades.grader" => 2, "task_grades.grader" => 1, "task_review_claims.holder_agent" => 1,
    "review_pending_actions.authorized_by" => 1, "agent_activities.agent" => 1,
    "agent_activities.supervisor_agent" => 1, "devops_shifts.lane" => 1, "gate_runs.actor" => 1,
    "release_events.actor" => 1, "releases.confirmed_by" => 1, "release_conductor_claims.holder_soul" => 1,
    "desk_records.actor" => 1, "agent_messages.soul_slug" => 1, "agent_message_events.actor" => 1,
    "agent_proposals.soul_slug" => 1, "agent_person_notes.soul_slug" => 1, "agent_sessions.soul" => 1,
    "agent_login_requests.soul" => 1, "agents.slug" => 1, "discord_channels.postable_souls" => 1,
    "tasks.metadata.devops.built_by" => 1, "tasks.metadata.devops.persona" => 1,
    "tasks.metadata.devops.approval_requested_by" => 1, "tasks.metadata.devops.builders" => 1,
    "tasks.metadata.devops.fix_forward" => 1, "tasks.metadata.reviewers" => 1,
    "task_events.metadata.reviewers" => 1, "activities.metadata.reporter" => 1,
    "activities.metadata.blocked_by" => 1, "agent_dispatchers.souls" => 1,
    "agent_message_events.detail.soul" => 1, "releases.duration_metrics.actor" => 1
  }.freeze

  test "counts every surface before, repoints it, and counts zero after" do
    before = surfaces_holding("xan")
    assert_equal EXPECTED, before.slice(*EXPECTED.keys), "every surface holds the planted xan row"
    assert_equal EXPECTED.keys.sort, before.keys.sort, "and no surface the migration knows was left unplanted"
    # The fixtures already seed the seat under `ray`, so the target side is read
    # as a DELTA over that floor.
    ray_before = M.counts("ray")

    migrate(:up)

    assert_equal({ "action_grades.grader" => 1 }, surfaces_holding("xan"),
                 "only the grade whose span already holds a ray grade is HELD; every other surface is empty")
    assert_equal 1, ActionGrade.where(agent_activity_id: @held, grader: "xan").count
    assert_equal 1, ActionGrade.where(agent_activity_id: @held, grader: "ray").count

    ray_after = M.counts("ray")
    landed = EXPECTED.to_h { |surface, _| [surface, ray_after.fetch(surface) - ray_before.fetch(surface)] }
    # Every xan row landed on ray except the one HELD grade (2 planted, 1 moved)
    # and the Agent row itself: ray is already seeded, so the planted xan row is
    # RETIRED rather than renamed (asserted by identity below).
    assert_equal EXPECTED.merge("action_grades.grader" => 1, "agents.slug" => 0), landed,
                 "each surface gains exactly the rows that left xan"
  end

  test "the JSON and array shapes are rewritten in place and nothing beside them moves" do
    migrate(:up)

    meta = @task.reload.metadata
    assert_equal "ray", meta.dig("devops", "built_by")
    assert_equal "ray", meta.dig("devops", "persona")
    assert_equal "ray", meta.dig("devops", "approval_requested_by")
    assert_equal %w[steffon ray], meta.dig("devops", "builders"), "the other author keeps its place"
    assert_equal %w[ray], meta.dig("devops", "fix_forward")
    assert_equal "docs", meta.dig("devops", "shape"), "an unrelated key is untouched"
    assert_equal [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "ray", "weight" => "light" }], meta["reviewers"]
    assert_equal [{ "slug" => "ray", "weight" => "light" }], M.shim("task_events").find(@event_id).metadata["reviewers"]
    assert_equal({ "reporter" => "ray", "blocked_by" => "ray" }, M.shim("activities").find(@activity_id).metadata)
    assert_equal "ray", @task.agent_slug
    assert_equal "ray", @task.blocked_by
    assert_equal %w[avi ray client_cto], M.shim("agent_dispatchers").find(@dispatcher_id).souls
    assert_equal %w[avi ray], M.shim("discord_channels").find(@channel_id).postable_souls
    assert_equal({ "soul" => "ray", "worker" => "d1" }, M.shim("agent_message_events").find(@message_event_id).detail)

    metrics = M.shim("releases").find(@release_id).duration_metrics
    assert_equal "ray", metrics.dig("tasks", 0, "stages", "building", "actor")
    assert_equal "ray", metrics.dig("release_steps", "ship_gate", "start_event", "actor")
    assert_equal "xan", metrics["note"], "only values under an actor key move"
  end

  test "the duplicate Agent row is retired by SQL and its children survive" do
    ray = Agent.find_by!(slug: "ray")
    assert Agent.exists?(slug: "xan"), "precondition: both rows present"
    activities_before = Activity.count

    migrate(:up)

    refute Agent.exists?(slug: "xan"), "the empty shell is gone"
    assert_equal ray.id, Agent.find_by!(slug: "ray").id, "the seeded row is the survivor"
    assert_equal activities_before, Activity.count, "a destroy would have cascaded; the SQL delete did not"
    assert_equal 1, Activity.where(agent_slug: "ray", task_slug: @task.slug).count
  end

  test "a lone xan row is renamed in place, keeping its id, and takes the ray portrait" do
    Agent.where(slug: "ray").delete_all
    legacy_id = Agent.find_by!(slug: "xan").id

    migrate(:up)

    seat = Agent.find_by!(slug: "ray")
    assert_equal legacy_id, seat.id, "same row, history kept"
    assert_equal "/agents/ray.webp", seat.avatar

    migrate(:down)
    assert_equal "/agents/xan.webp", Agent.find(legacy_id).avatar
    assert_equal "xan", Agent.find(legacy_id).slug
  end

  test "running up twice changes nothing the second time" do
    migrate(:up)
    snapshot = -> { [surfaces_holding("xan"), surfaces_holding("ray"), @task.reload.metadata, Agent.pluck(:slug).sort] }
    first = snapshot.call

    migrate(:up)

    assert_equal first, snapshot.call, "the second run is a no-op — every write is WHERE value = 'xan'"
  end

  test "down reverses the repoint" do
    migrate(:up)
    migrate(:down)

    # `down` is the honest reverse of a rename: it moves every ray value,
    # including fixture rows seeded under the new slug — so assert the planted
    # rows by identity, not by a count that also sees the fixtures.
    assert_equal "xan", @task.reload.agent_slug
    assert_equal "xan", @task.blocked_by
    assert_equal "xan", M.shim("task_events").find(@event_id).actor
    assert_equal "xan", @task.metadata.dig("devops", "built_by")
    assert_equal %w[steffon xan], @task.metadata.dig("devops", "builders")
    assert_equal %w[avi xan client_cto], M.shim("agent_dispatchers").find(@dispatcher_id).souls
    assert_equal "xan", M.shim("agent_messages").find(@message_id).soul_slug
    assert_equal 1, surfaces_holding("xan")["agents.slug"], "the seat is back under its old slug"
    assert_empty surfaces_holding("ray").except("action_grades.grader"),
                 "nothing but the guarded grade pair still says ray"
  end

  test "the task_grades default follows the slug both ways" do
    default = -> { TaskGrade.connection.columns(:task_grades).find { |c| c.name == "grader" }.default }
    assert_equal "ray", default.call, "the default this migration left (RenameRaySoulToAlex later moved it to mason)"

    migrate(:down)
    assert_equal "xan", default.call
    migrate(:up)
    assert_equal "ray", default.call
  end
end
