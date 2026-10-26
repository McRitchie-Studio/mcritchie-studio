require "test_helper"
require Rails.root.join("db/migrate/20261025230000_rename_ray_soul_to_alex.rb").to_s

# [unit] RenameRaySoulToAlex repoints EVERY stored `ray` soul value to `alex`,
# except the grader key and the devops lane, which follow the orchestrator's acts
# to `mason` (the split). It counts each surface before and after, runs a second
# time without changing a row, and reverses. The rows are planted through the
# migration's own schema shims because the live models now CANONICALIZE `ray`
# on write — the only way to build a row the way a deployed database still holds
# it is to bypass them, exactly as the migration does.
class RenameRaySoulToAlexMigrationTest < ActiveSupport::TestCase
  M = RenameRaySoulToAlex

  setup do
    Agent.where(slug: "ray").delete_all
    @now = Time.current
    plant_ray_rows
  end

  def migrate(direction) = capture_io { M.new.public_send(direction) }

  def ins(table, row)
    shim = M.shim(table)
    stamps = { created_at: @now, updated_at: @now }.select { |col, _| shim.column_names.include?(col.to_s) }
    shim.insert_all([stamps.merge(row)]).first["id"]
  end

  # One `ray` on every surface the migration knows, plus a `ray` sibling on the
  # unique-keyed ones where the guard has to hold.
  def plant_ray_rows
    ins("agents", name: "Ray (legacy row)", slug: "ray", avatar: "/agents/ray.webp")

    @task = Task.create!(title: "migration sample task row", stage: "submitted",
                         metadata: { "devops" => { "shape" => "docs" } })
    @task.update_columns(
      agent_slug: "ray", blocked_by: "ray",
      metadata: {
        "devops" => { "shape" => "docs", "built_by" => "ray", "persona" => "ray",
                      "approval_requested_by" => "ray", "builders" => %w[steffon ray],
                      "fix_forward" => %w[ray] },
        "reviewers" => [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "ray", "weight" => "light" }]
      }
    )

    @event_id = ins("task_events", task_slug: @task.slug, to_stage: "reviewed", actor: "ray", occurred_at: @now,
                                   metadata: { "reviewers" => [{ "slug" => "ray", "weight" => "light" }] })
    @activity_id = ins("activities", agent_slug: "ray", activity_type: "comment", task_slug: @task.slug,
                                     metadata: { "reporter" => "ray", "blocked_by" => "ray" })

    @span = ins("agent_activities", session_id: "mig-sess", category: "Explore", reason_slug: "sample",
                                    opened_at: @now, agent: "ray", supervisor_agent: "ray")
    ins("action_grades", agent_activity_id: @span, grader: "ray", disposition: "good", slug: "a lesson under the old slug")
    # A second span that ALREADY holds a mason grade beside its ray one — the
    # unique-key guard must leave that ray row alone rather than collide.
    @held = ins("agent_activities", session_id: "mig-sess", category: "Verify", reason_slug: "held", opened_at: @now)
    ins("action_grades", agent_activity_id: @held, grader: "ray", disposition: "good", slug: "old")
    ins("action_grades", agent_activity_id: @held, grader: "mason", disposition: "not", slug: "new")

    ins("task_grades", task_slug: @task.slug, grader: "ray", verdict: "clean", graded_at: @now)
    ins("task_review_claims", task_slug: @task.slug, holder_agent: "ray")
    ins("review_pending_actions", task_slug: @task.slug, repo: "mcritchie-studio", head_sha: "abc1234", pr_number: 1,
                                  verdict: "merge", authorized_by: "ray", expires_at: @now + 1.hour)
    ins("devops_shifts", lane: "ray")
    ins("gate_runs", subject_type: "task", subject_slug: @task.slug, key: "g2b_light", attempt: 1,
                     actor: "ray", started_at: @now)
    @release_id = ins("releases", slug: "rel-sample", confirmed_by: "ray",
                                  duration_metrics: { "tasks" => [{ "stages" => { "building" => { "actor" => "ray" } } }],
                                                      "release_steps" => { "ship_gate" => { "start_event" => { "actor" => "ray" } } },
                                                      "note" => "ray" })
    ins("release_events", release_slug: "rel-sample", step: "ship_gate", status: "started", actor: "ray", occurred_at: @now)
    ins("release_conductor_claims", release_slug: "rel-sample", role: "conductor", holder_soul: "ray")
    ins("desk_records", worktree_path: "/tmp/desk-sample", actor: "ray")
    ins("usages", agent_slug: "ray", period_date: Date.current, period_type: "daily", model: "m")
    ins("skill_assignments", agent_slug: "ray", skill_slug: "ruby-dev")

    @message_id = ins("agent_messages", channel: "web", channel_ref: "build:1", external_id: "mig-1",
                                        thread_key: "web:build:1", soul_slug: "ray")
    @message_event_id = ins("agent_message_events", agent_message_id: @message_id, kind: "claimed", actor: "ray",
                                                    detail: { "soul" => "ray", "worker" => "d1" })
    ins("agent_proposals", capability: "c", channel: "web", channel_ref: "build:1", expires_at: @now + 1.hour,
                           kind: "ask", soul_slug: "ray", thread_key: "web:build:1")
    person = ins("agent_people", display_name: "Sample Person")
    ins("agent_person_notes", agent_person_id: person, body: "likes ray", fingerprint: "fp-1", noted_at: @now, soul_slug: "ray")
    ins("agent_sessions", slug: "sess-mig-0001", soul: "ray", tier: "admin", issued_by: "operator_grant",
                          issued_at: @now, expires_at: @now + 1.hour)
    ins("agent_login_requests", slug: "alr-mig-0001", soul: "ray", harness_session_id: "h-1", collect_digest: "c",
                                phrase_digest: "p", requested_at: @now)
    @channel_id = ins("discord_channels", external_id: "c-1", guild_external_id: "g-1", kind: "text", name: "desk",
                                          postable_souls: %w[avi ray])
    @dispatcher_id = ins("agent_dispatchers", worker_id: "d-mig", last_seen_at: @now, souls: %w[avi ray client_cto])
  end

  def surfaces_holding(value) = M.counts(value).select { |_, n| n.positive? }

  EXPECTED = {
    "activities.agent_slug" => 1, "usages.agent_slug" => 1, "skill_assignments.agent_slug" => 1,
    "tasks.agent_slug" => 1, "tasks.blocked_by" => 1, "task_events.actor" => 1,
    "task_review_claims.holder_agent" => 1,
    "review_pending_actions.authorized_by" => 1, "agent_activities.agent" => 1,
    "agent_activities.supervisor_agent" => 1, "gate_runs.actor" => 1,
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

  # The split: these follow the orchestrator's acts to mason, never to alex.
  SPLIT_EXPECTED = { "action_grades.grader" => 2, "task_grades.grader" => 1, "devops_shifts.lane" => 1 }.freeze

  test "counts every surface before, repoints it, and counts zero after" do
    before = surfaces_holding("ray")
    assert_equal EXPECTED, before.slice(*EXPECTED.keys), "every surface holds the planted ray row"
    assert_equal EXPECTED.keys.sort, before.keys.sort, "and no surface the migration knows was left unplanted"
    assert_equal SPLIT_EXPECTED, M.split_counts("ray"), "every split surface holds the planted ray row"
    # The fixtures already seed the seat under `alex`, so the target side is read
    # as a DELTA over that floor.
    alex_before = M.counts("alex")
    mason_before = M.split_counts("mason")

    migrate(:up)

    assert_empty surfaces_holding("ray"), "every persona surface is empty"
    assert_equal({ "action_grades.grader" => 1, "task_grades.grader" => 0, "devops_shifts.lane" => 0 },
                 M.split_counts("ray"), "only the grade whose span already holds a mason grade is HELD")
    assert_equal 1, ActionGrade.where(agent_activity_id: @held, grader: "ray").count
    assert_equal 1, ActionGrade.where(agent_activity_id: @held, grader: "mason").count

    alex_after = M.counts("alex")
    landed = EXPECTED.to_h { |surface, _| [surface, alex_after.fetch(surface) - alex_before.fetch(surface)] }
    # Every ray row landed on alex except the Agent row itself: alex is already
    # seeded, so the planted ray row is RETIRED rather than renamed (asserted by
    # identity below).
    assert_equal EXPECTED.merge("agents.slug" => 0), landed, "each surface gains exactly the rows that left ray"

    mason_after = M.split_counts("mason")
    split_landed = SPLIT_EXPECTED.to_h { |surface, _| [surface, mason_after.fetch(surface) - mason_before.fetch(surface)] }
    assert_equal SPLIT_EXPECTED.merge("action_grades.grader" => 1), split_landed,
                 "the grader key and the lane land on mason (2 grades planted, 1 held)"
    assert_equal 0, ActionGrade.where(grader: "alex").count, "no grade is ever relabelled to the persona"
    assert_equal 0, DevopsShift.where(lane: "alex").count, "the orchestrator lane never becomes the persona's"
  end

  test "the seat reads Alex, with the mad-lad portrait and its emoji, and back" do
    Agent.where(slug: "alex").delete_all
    seat_id = Agent.find_by!(slug: "ray").id
    M.shim("agents").where(id: seat_id).update_all(name: "Ritch", metadata: { "emoji" => "🧭", "color" => "#818CF8" })

    migrate(:up)

    seat = Agent.find(seat_id)
    assert_equal ["alex", "Alex", "/agents/alex.webp", "🧑🏻", "#818CF8"],
                 [seat.slug, seat.name, seat.avatar, seat.metadata["emoji"], seat.metadata["color"]]

    migrate(:down)
    seat.reload
    assert_equal ["ray", "Ritch", "/agents/ray.webp", "🧭"], [seat.slug, seat.name, seat.avatar, seat.metadata["emoji"]]
  end

  test "a hand-set name and emoji are left alone" do
    Agent.where(slug: "alex").delete_all
    seat_id = Agent.find_by!(slug: "ray").id
    M.shim("agents").where(id: seat_id).update_all(name: "Custom", metadata: { "emoji" => "🦄" })

    migrate(:up)

    assert_equal ["Custom", "🦄"], Agent.find(seat_id).then { |a| [a.name, a.metadata["emoji"]] }
  end

  test "the JSON and array shapes are rewritten in place and nothing beside them moves" do
    migrate(:up)

    meta = @task.reload.metadata
    assert_equal "alex", meta.dig("devops", "built_by")
    assert_equal "alex", meta.dig("devops", "persona")
    assert_equal "alex", meta.dig("devops", "approval_requested_by")
    assert_equal %w[steffon alex], meta.dig("devops", "builders"), "the other author keeps its place"
    assert_equal %w[alex], meta.dig("devops", "fix_forward")
    assert_equal "docs", meta.dig("devops", "shape"), "an unrelated key is untouched"
    assert_equal [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "alex", "weight" => "light" }], meta["reviewers"]
    assert_equal [{ "slug" => "alex", "weight" => "light" }], M.shim("task_events").find(@event_id).metadata["reviewers"]
    assert_equal({ "reporter" => "alex", "blocked_by" => "alex" }, M.shim("activities").find(@activity_id).metadata)
    assert_equal "alex", @task.agent_slug
    assert_equal "alex", @task.blocked_by
    assert_equal %w[avi alex client_cto], M.shim("agent_dispatchers").find(@dispatcher_id).souls
    assert_equal %w[avi alex], M.shim("discord_channels").find(@channel_id).postable_souls
    assert_equal({ "soul" => "alex", "worker" => "d1" }, M.shim("agent_message_events").find(@message_event_id).detail)

    metrics = M.shim("releases").find(@release_id).duration_metrics
    assert_equal "alex", metrics.dig("tasks", 0, "stages", "building", "actor")
    assert_equal "alex", metrics.dig("release_steps", "ship_gate", "start_event", "actor")
    assert_equal "ray", metrics["note"], "only values under an actor key move"
  end

  test "the duplicate Agent row is retired by SQL and its children survive" do
    alex = Agent.find_by!(slug: "alex")
    assert Agent.exists?(slug: "ray"), "precondition: both rows present"
    activities_before = Activity.count

    migrate(:up)

    refute Agent.exists?(slug: "ray"), "the empty shell is gone"
    assert_equal alex.id, Agent.find_by!(slug: "alex").id, "the seeded row is the survivor"
    assert_equal activities_before, Activity.count, "a destroy would have cascaded; the SQL delete did not"
    assert_equal 1, Activity.where(agent_slug: "alex", task_slug: @task.slug).count
  end

  test "a lone ray row is renamed in place, keeping its id, and takes the alex portrait" do
    Agent.where(slug: "alex").delete_all
    legacy_id = Agent.find_by!(slug: "ray").id

    migrate(:up)

    seat = Agent.find_by!(slug: "alex")
    assert_equal legacy_id, seat.id, "same row, history kept"
    assert_equal "/agents/alex.webp", seat.avatar

    migrate(:down)
    assert_equal "/agents/ray.webp", Agent.find(legacy_id).avatar
    assert_equal "ray", Agent.find(legacy_id).slug
  end

  test "running up twice changes nothing the second time" do
    migrate(:up)
    snapshot = -> { [surfaces_holding("ray"), surfaces_holding("alex"), M.split_counts("ray"), M.split_counts("mason"),
                     @task.reload.metadata, Agent.pluck(:slug, :name, :avatar).sort] }
    first = snapshot.call

    migrate(:up)

    assert_equal first, snapshot.call, "the second run is a no-op — every write is WHERE value = 'ray'"
  end

  test "down reverses the repoint" do
    migrate(:up)
    migrate(:down)

    # `down` is the honest reverse of a rename: it moves every ray value,
    # including fixture rows seeded under the new slug — so assert the planted
    # rows by identity, not by a count that also sees the fixtures.
    assert_equal "ray", @task.reload.agent_slug
    assert_equal "ray", @task.blocked_by
    assert_equal "ray", M.shim("task_events").find(@event_id).actor
    assert_equal "ray", @task.metadata.dig("devops", "built_by")
    assert_equal %w[steffon ray], @task.metadata.dig("devops", "builders")
    assert_equal %w[avi ray client_cto], M.shim("agent_dispatchers").find(@dispatcher_id).souls
    assert_equal "ray", M.shim("agent_messages").find(@message_id).soul_slug
    assert_equal 1, surfaces_holding("ray")["agents.slug"], "the seat is back under its old slug"
    assert_empty surfaces_holding("alex"), "nothing still says alex"
    assert_equal SPLIT_EXPECTED, M.split_counts("ray"), "the grades and the lane are back on ray"
  end

  test "the task_grades default follows the grader seat to mason and back" do
    default = -> { TaskGrade.connection.columns(:task_grades).find { |c| c.name == "grader" }.default }
    assert_equal "mason", default.call, "schema.rb carries the migrated default: the grader is Mason"

    migrate(:down)
    assert_equal "ray", default.call
    migrate(:up)
    assert_equal "mason", default.call
  end
end
