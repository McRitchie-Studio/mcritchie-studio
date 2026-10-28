require "test_helper"
require Rails.root.join("db/migrate/20261028180000_merge_rex_soul_into_alex.rb").to_s

# [unit] MergeRexSoulIntoAlex folds every stored `rex` soul value onto `alex`
# (rex-folds-into-alex, accountability-chart ruling 3). A MERGE: both agent rows
# exist, so the rex row is retired once its children moved; rows whose alex
# sibling already owns a unique key are settled (a skill dropped, a usage summed),
# lists that named both seats keep one `alex`, and a second run changes nothing.
# Rows are planted through the migration's own schema shims, because the live
# models canonicalize `rex` on write now.
class MergeRexSoulIntoAlexMigrationTest < ActiveSupport::TestCase
  M = MergeRexSoulIntoAlex

  setup do
    Agent.where(slug: "rex").delete_all
    @now = Time.current
    plant_rex_rows
  end

  def migrate(direction) = capture_io { M.new.public_send(direction) }

  def ins(table, row)
    shim = M.shim(table)
    stamps = { created_at: @now, updated_at: @now }.select { |col, _| shim.column_names.include?(col.to_s) }
    shim.insert_all([stamps.merge(row)]).first["id"]
  end

  def plant_rex_rows
    @rex_id = ins("agents", name: "Rex", slug: "rex", status: "active", agent_type: "specialist")

    @task = Task.create!(title: "rex merge sample task row", stage: "submitted",
                         metadata: { "devops" => { "shape" => "docs" } })
    @task.update_columns(
      agent_slug: "rex", blocked_by: "rex",
      metadata: {
        "devops" => { "shape" => "docs", "built_by" => "rex", "builders" => %w[alex rex steffon],
                      "fix_forward" => %w[rex] },
        "reviewers" => [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "rex", "weight" => "light" }]
      }
    )
    @event_id = ins("task_events", task_slug: @task.slug, to_stage: "reviewed", actor: "rex", occurred_at: @now,
                                   metadata: { "reviewers" => [{ "slug" => "alex", "weight" => "light" },
                                                               { "slug" => "rex", "weight" => "light" }] })
    @activity_id = ins("activities", agent_slug: "rex", activity_type: "comment", task_slug: @task.slug,
                                     metadata: { "reporter" => "rex" })
    @span = ins("agent_activities", session_id: "rex-sess", category: "Explore", reason_slug: "sample",
                                    opened_at: @now, agent: "rex")
    @message_id = ins("agent_messages", channel: "web", channel_ref: "build:9", external_id: "rex-1",
                                        thread_key: "web:build:9", soul_slug: "rex")

    # Unique-key collisions a merge must settle (the skills exist first: a
    # skill_assignment is keyed to skills.slug).
    ins("skills", name: "Rex Only", slug: "rex-only", category: "marketing")
    ins("skill_assignments", agent_slug: "rex", skill_slug: "ruby-dev")
    ins("skill_assignments", agent_slug: "alex", skill_slug: "ruby-dev") unless
      SkillAssignment.exists?(agent_slug: "alex", skill_slug: "ruby-dev")
    ins("skill_assignments", agent_slug: "rex", skill_slug: "rex-only")
    ins("usages", agent_slug: "rex", period_date: Date.current, period_type: "daily", model: "m",
                  api_calls: 3, tokens_in: 100, tokens_out: 10, cost: 1.5)
    @alex_usage = ins("usages", agent_slug: "alex", period_date: Date.current, period_type: "daily", model: "m",
                                api_calls: 2, tokens_in: 50, tokens_out: 5, cost: 0.5)
    ins("usages", agent_slug: "rex", period_date: Date.current - 1, period_type: "daily", model: "m", api_calls: 7)

    @channel_id = ins("discord_channels", external_id: "c-rex", guild_external_id: "g-1", kind: "text", name: "desk",
                                          postable_souls: %w[alex rex])
    @dispatcher_id = ins("agent_dispatchers", worker_id: "d-rex", last_seen_at: @now, souls: %w[avi rex])
  end

  def surfaces_holding(value) = M.counts(value).select { |_, n| n.positive? }

  test "every rex surface is empty after, and the rex agent row is retired" do
    assert_includes surfaces_holding("rex").keys, "agents.slug"
    alex_row = Agent.find_by!(slug: "alex")

    migrate(:up)

    assert_empty surfaces_holding("rex"), "no row anywhere still names rex"
    refute Agent.exists?(slug: "rex"), "the empty rex shell is gone"
    assert_equal alex_row.id, Agent.find_by!(slug: "alex").id, "alex keeps its own row"
    assert_equal "alex", @task.reload.agent_slug
    assert_equal "alex", @task.blocked_by
    assert_equal "alex", M.shim("activities").find(@activity_id).agent_slug
    assert_equal "alex", M.shim("agent_activities").find(@span).agent
    assert_equal "alex", M.shim("agent_messages").find(@message_id).soul_slug
    assert_equal "alex", M.shim("task_events").find(@event_id).actor
  end

  test "held unique rows are settled: a duplicate skill dropped, a same-period usage summed" do
    migrate(:up)

    assert_equal 1, SkillAssignment.where(agent_slug: "alex", skill_slug: "ruby-dev").count
    assert SkillAssignment.exists?(agent_slug: "alex", skill_slug: "rex-only"),
           "a skill only rex held moves to alex"

    summed = M.shim("usages").find(@alex_usage)
    assert_equal [5, 150, 15, BigDecimal("2.0")], [summed.api_calls, summed.tokens_in, summed.tokens_out, summed.cost]
    assert_equal 7, M.shim("usages").find_by!(agent_slug: "alex", period_date: Date.current - 1).api_calls,
                 "a period alex never used simply moves"
  end

  # Two usage rows may share a period when the model is NULL (NULLs are distinct
  # under the unique index). Every rex counter lands once, on one alex row.
  test "null-model usages are summed once, onto one alex row" do
    day = Date.current - 5
    ins("usages", agent_slug: "rex", period_date: day, period_type: "daily", model: nil, api_calls: 3)
    ins("usages", agent_slug: "rex", period_date: day, period_type: "daily", model: nil, api_calls: 4)
    first = ins("usages", agent_slug: "alex", period_date: day, period_type: "daily", model: nil, api_calls: 10)
    second = ins("usages", agent_slug: "alex", period_date: day, period_type: "daily", model: nil, api_calls: 20)

    migrate(:up)

    rows = M.shim("usages").where(period_date: day, period_type: "daily", model: nil)
    assert_equal 0, rows.where(agent_slug: "rex").count
    assert_equal 37, rows.sum(:api_calls), "every call counted exactly once"
    assert_equal [17, 20], [M.shim("usages").find(first).api_calls, M.shim("usages").find(second).api_calls]
  end

  test "lists that named both seats keep one alex, in place" do
    migrate(:up)

    meta = @task.reload.metadata
    assert_equal "alex", meta.dig("devops", "built_by")
    assert_equal %w[alex steffon], meta.dig("devops", "builders"), "rex and alex are ONE author"
    assert_equal %w[alex], meta.dig("devops", "fix_forward")
    assert_equal [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "alex", "weight" => "light" }], meta["reviewers"]
    assert_equal [{ "slug" => "alex", "weight" => "light" }], M.shim("task_events").find(@event_id).metadata["reviewers"]
    assert_equal %w[alex], M.shim("discord_channels").find(@channel_id).postable_souls
    assert_equal %w[avi alex], M.shim("agent_dispatchers").find(@dispatcher_id).souls
  end

  test "a second run changes nothing, and down is a no-op that says so" do
    migrate(:up)
    snapshot = M.counts("alex")

    migrate(:up)
    assert_equal snapshot, M.counts("alex")

    # `say` prints only while Migration.verbose is on, and another test may have
    # turned it off; pin it so the message is measured, not the suite order.
    was = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = true
    out, = migrate(:down)
    ActiveRecord::Migration.verbose = was
    assert_match(/changes nothing/, out)
    assert_equal snapshot, M.counts("alex"), "down moves no row back"
  end

  test "with no alex row the rex row becomes alex in place, children attached" do
    M.shim("usages").where(agent_slug: "alex").delete_all
    M.shim("skill_assignments").where(agent_slug: "alex").delete_all
    Agent.where(slug: "alex").delete_all

    migrate(:up)

    seat = Agent.find(@rex_id)
    assert_equal "alex", seat.slug, "the seat's history is kept on its own row"
    assert_equal "alex", @task.reload.agent_slug
  end
end
