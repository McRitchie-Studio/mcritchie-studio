require "test_helper"

# [component] the atomic trajectory table partial — one row per action, bucketed
# into per-stage group tbodies, with the ported dense columns and outcome accents.
# The read-only columns mutate nothing; the trailing feedback columns (the inline
# Alex/McRitchie radios) need a real id, so the rows are persisted.
class HeartbeatTrajectoryTableTest < ActionView::TestCase
  def action(attrs)
    AtomicAction.create!({ session_id: "s", kind: "edit", occurred_at: Time.current,
                           outcome: "ok", actor: "agent" }.merge(attrs))
  end

  test "renders a row per action with the trajectory columns and grouping" do
    boot = action(seq: 0, stage: nil, actor: "harness",
                  event_slug: "Boot the session runtime", result_slug: "Identity resolved")
    edit = action(seq: 1, stage: "building", task_slug: "demo-task", mascot: "rotom",
                  model: "claude-opus-4-8", tokens_in: 9400, tokens_out: 360, cost: 0.06,
                  event_slug: "Implement the view code", result_slug: "Controller and view written")
    groups = [[nil, [boot]], ["building", [edit]]]

    render partial: "heartbeat/trajectory_table", locals: { groups: groups, pokemon_by_slug: {} }

    assert_select "table[data-test=heartbeat-table]"
    assert_select "tr[data-test=heartbeat-row]", 2
    # null stage groups under "Session"; the build stage under its own group
    assert_select "tbody[data-test=heartbeat-group][data-stage=session]"
    assert_select "tbody[data-test=heartbeat-group][data-stage=building]"
    assert_includes rendered, "Boot the session runtime"
    assert_includes rendered, "Implement the view code"
    # dense ported columns: short model, compact in/out tokens
    assert_includes rendered, "opus-4-8"
    assert_includes rendered, "9.4k/360"
    # outcome badge + hover-title tooltips on Stage and Actor
    assert_select "span.hb-outcome", text: "ok", minimum: 1
    assert_select "td.hb-stage-cell[title]"
    assert_select "span.hb-actor[title=?]", "Claude Code / Codex runtime"
  end

  test "rows present oldest to newest within a group" do
    first  = action(seq: 0, stage: "building", event_slug: "alpha first edit")
    second = action(seq: 1, stage: "building", event_slug: "omega later edit")
    render partial: "heartbeat/trajectory_table",
           locals: { groups: [["building", [first, second]]], pokemon_by_slug: {} }

    assert_operator rendered.index("alpha first edit"), :<, rendered.index("omega later edit")
  end

  test "falls back to the mascot slug when no Pokemon record is found" do
    render partial: "heartbeat/trajectory_table",
           locals: { groups: [["building", [action(seq: 0, stage: "building", mascot: "rotom")]]],
                     pokemon_by_slug: {} }
    assert_includes rendered, "Rotom"
  end

  test "prefers the looked-up Pokemon name over the raw slug" do
    poke = Pokemon.new(slug: "mr-mime", name: "Mr. Mime")
    render partial: "heartbeat/trajectory_table",
           locals: { groups: [["building", [action(seq: 0, stage: "building", mascot: "mr-mime")]]],
                     pokemon_by_slug: { "mr-mime" => poke } }
    assert_includes rendered, "Mr. Mime"
  end

  test "the mascot column header now reads Agent" do
    render partial: "heartbeat/trajectory_table", locals: { groups: [], pokemon_by_slug: {} }

    assert_select "thead th", text: "Agent"
    assert_select "thead th", text: "Pokémon", count: 0
  end

  test "an action inherits its span's acting soul and stacks it over the base mascot" do
    carl = Agent.new(slug: "carl", name: "Carl", metadata: { "emoji" => "🛠" })
    act  = action(seq: 0, stage: "building", mascot: "sandshrew")

    render partial: "heartbeat/trajectory_table",
           locals: { groups: [["building", [act]]], pokemon_by_slug: {},
                     agents_by_slug: { "carl" => carl }, agent_slug_by_action: { act.id => "carl" } }

    assert_select "[data-test=agent-stack]"
    assert_select "[data-test=agent-soul][data-soul=carl][title=?]", "Carl"
    # the base mascot name rides on its avatar title
    assert_includes rendered, "Sandshrew"
  end

  test "an action with no inherited soul falls back to just its mascot" do
    render partial: "heartbeat/trajectory_table",
           locals: { groups: [["building", [action(seq: 0, stage: "building", mascot: "rotom")]]],
                     pokemon_by_slug: {} }

    assert_select "[data-test=agent-stack]", false
    assert_includes rendered, "Rotom"
  end

  test "a shared turn fades the tokens and cost cells of the later action, not the first" do
    first  = action(seq: 0, stage: "building", source_turn_uuid: "turn-A",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    second = action(seq: 1, stage: "building", source_turn_uuid: "turn-A",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    shared = Set.new([second.id])

    render partial: "heartbeat/trajectory_table",
           locals: { groups: [["building", [first, second]]], pokemon_by_slug: {},
                     shared_turn_ids: shared }

    assert_select "tr[data-seq='0'] td.hb-turn-shared", false
    assert_select "tr[data-seq='1'] td.hb-turn-shared", 2
  end
end
