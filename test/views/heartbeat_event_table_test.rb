require "test_helper"

# [component] the event-grouped heartbeat table partial — the PRIMARY rows are
# agent-narrated AtomicEvent spans (category · reason -> outcome), each rolling up
# the raw AtomicActions attributed to it as a read-only drill-down. Actions with a
# null atomic_event_id render in the trailing "Unlabeled" group. Read-only: the
# table has no inline grading controls (grading lives in the drawer).
class HeartbeatEventTableTest < ActionView::TestCase
  def event(**attrs)
    AtomicEvent.create!({ session_id: "s", category: "Explore", reason_slug: "find issue with api",
                          opened_at: Time.current, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  def action(**attrs)
    AtomicAction.create!({ session_id: "s", kind: "grep", outcome: "ok", actor: "agent",
                           seq: attrs.fetch(:seq, 0), occurred_at: Time.current }.merge(attrs))
  end

  test "[component] renders each span as a row with category, reason, and outcome" do
    closed = event(category: "Explore", reason_slug: "find issue with api",
                   outcome_slug: "found the nil-guard", closed_at: Time.current, seq: 0)
    a1 = action(atomic_event_id: closed.id, seq: 0, kind: "grep",
                event_slug: "Grep for the capture seam", input: "grep -rn AtomicAction app/models")
    a2 = action(atomic_event_id: closed.id, seq: 1, kind: "read", event_slug: "Read the model")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[closed, [a1, a2]]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "table[data-test=heartbeat-event-table]"
    assert_select "tbody[data-test=heartbeat-event][data-category=Explore]"
    assert_select "tbody[data-test=heartbeat-event] tr[data-test=heartbeat-event-row]", 1
    assert_select ".hb-catchip", text: "Explore"
    assert_includes rendered, "find issue with api"
    assert_includes rendered, "found the nil-guard"
    # the count of attributed actions
    assert_select "[data-test=event-action-count]", text: "2 actions"
  end

  test "[component] an open span (no outcome) renders the in-progress placeholder" do
    open = event(category: "Workflow", reason_slug: "certify and open the PR",
                 outcome_slug: nil, closed_at: nil, seq: 0)

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[open, []]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "[data-test=event-in-progress]"
    assert_match(/in progress/, rendered)
    assert_no_match(/found the nil-guard/, rendered)
  end

  test "[component] a span drills down into its attributed actions with kind and input" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    a1 = action(atomic_event_id: ev.id, seq: 0, kind: "grep",
                event_slug: "Grep the seam", input: "grep -rn AtomicEvent app/models")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1]]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "tr[data-test=heartbeat-event-action]", 1
    assert_select "tr[data-test=heartbeat-event-action] .hb-kind", text: "grep"
    assert_includes rendered, "Grep the seam"
    # the raw tool-call input surfaces in the drill-down
    assert_includes rendered, "grep -rn AtomicEvent app/models"
  end

  test "[component] actions drill down oldest to newest within a span" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    first  = action(atomic_event_id: ev.id, seq: 0, event_slug: "alpha first read")
    second = action(atomic_event_id: ev.id, seq: 1, event_slug: "omega later read")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [first, second]]], unlabeled: [], pokemon_by_slug: {} }

    assert_operator rendered.index("alpha first read"), :<, rendered.index("omega later read")
  end

  test "[component] actions with a null span land in the read-only Unlabeled group" do
    orphan = action(atomic_event_id: nil, seq: 0, kind: "bash",
                    event_slug: "Unnarrated boot step", input: "spin up the runtime")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [], unlabeled: [orphan], pokemon_by_slug: {} }

    assert_select "tbody[data-test=heartbeat-unlabeled]"
    assert_select "tbody[data-test=heartbeat-unlabeled] .hb-catchip", text: "Unlabeled"
    assert_select "tbody[data-test=heartbeat-unlabeled] tr[data-test=heartbeat-event-action]", 1
    assert_includes rendered, "Unnarrated boot step"
  end

  test "[component] the table is read-only — no inline grading radios" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    a1 = action(atomic_event_id: ev.id, seq: 0)

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1]]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "input[type=radio]", false
    # but a drilled-down action still links to its grading drawer
    assert_includes rendered, heartbeat_feedback_path(a1)
  end

  test "[component] the span row rolls up its actions into Pokémon, model, tokens, and cost" do
    ev = event(seq: 0, mascot: "snorlax", closed_at: Time.current, outcome_slug: "done")
    a1 = action(atomic_event_id: ev.id, seq: 0, model: "claude-opus-4-8", tokens_in: 9400, tokens_out: 360, cost: 0.05)
    a2 = action(atomic_event_id: ev.id, seq: 1, model: "claude-opus-4-8", tokens_in: 6800, tokens_out: 2400, cost: 0.09)

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1, a2]]], unlabeled: [], pokemon_by_slug: {} }

    # aggregated across the span's actions, not per-action
    assert_select "[data-test=event-tokens]", text: "16.2k/2.8k"
    assert_select "[data-test=event-cost]", text: "$0.1400"
    assert_select "[data-test=event-model]", text: "opus-4-8"
    # the span mascot resolves to a name (slug titleized here — no seeded Pokémon passed)
    assert_select "[data-test=event-mascot]", text: /Snorlax/
  end

  test "[component] the span row shows a distinct open vs done status badge" do
    open_span = event(seq: 0, reason_slug: "certify and open the PR", closed_at: nil, outcome_slug: nil)
    done_span = event(seq: 1, reason_slug: "run the unit suite", closed_at: Time.current, outcome_slug: "green")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[open_span, []], [done_span, []]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "[data-test=event-status]", text: "open"
    assert_select "[data-test=event-status]", text: "done"
  end

  test "[component] each span exposes a grade affordance opening its span-grade drawer" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "[data-test=event-grade-open]", 1
    assert_includes rendered, heartbeat_event_feedback_path(ev)
  end

  test "[component] a shared turn fades the tokens AND cost cells of every action after the first" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    first  = action(atomic_event_id: ev.id, seq: 0, source_turn_uuid: "turn-A",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    second = action(atomic_event_id: ev.id, seq: 1, source_turn_uuid: "turn-A",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    # the controller's session-level walk marks the 2nd action of the shared turn
    shared = Set.new([second.id])

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [first, second]]], unlabeled: [], pokemon_by_slug: {},
                     shared_turn_ids: shared }

    # the turn's first action keeps its normal color — no faded cell
    assert_select "tr[data-seq='0'] td.hb-turn-shared", false
    # the 2nd action fades BOTH its tokens and its cost cell, each with the inherit tooltip
    assert_select "tr[data-seq='1'] td.hb-turn-shared", 2
    assert_select "tr[data-seq='1'] td.hb-turn-shared[title=?]",
                  "shared with this turn's first action", 2
    # only the color changes — the value itself is untouched
    assert_select "tr[data-seq='1'] td.hb-turn-shared", text: "9.4k/360"
  end

  test "[component] a solo-turn action and a blank-turn action are never faded" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    solo  = action(atomic_event_id: ev.id, seq: 0, source_turn_uuid: "turn-solo",
                   tokens_in: 100, tokens_out: 10, cost: 0.01)
    blank = action(atomic_event_id: ev.id, seq: 1, source_turn_uuid: nil,
                   tokens_in: 200, tokens_out: 20, cost: 0.02)
    # neither is a duplicate, so the controller flags nothing
    shared = Set.new

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [solo, blank]]], unlabeled: [], pokemon_by_slug: {},
                     shared_turn_ids: shared }

    assert_select "td.hb-turn-shared", false
  end

  test "[component] exactly one primary per turn even when the turn's calls split across spans" do
    span1 = event(seq: 0, reason_slug: "first span", closed_at: Time.current, outcome_slug: "done")
    span2 = event(seq: 1, reason_slug: "second span", closed_at: Time.current, outcome_slug: "done")
    primary = action(atomic_event_id: span1.id, seq: 0, source_turn_uuid: "turn-split",
                     tokens_in: 9400, tokens_out: 360, cost: 0.05)
    echo    = action(atomic_event_id: span2.id, seq: 1, source_turn_uuid: "turn-split",
                     tokens_in: 9400, tokens_out: 360, cost: 0.05)
    # the controller walks the WHOLE session chronologically, so the echo (in span2)
    # is the sole duplicate even though it lives under a different span than the primary
    shared = Set.new([echo.id])

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[span1, [primary]], [span2, [echo]]], unlabeled: [],
                     pokemon_by_slug: {}, shared_turn_ids: shared }

    # the primary (in span1) stays full color; only the echo (in span2) fades its two cells
    assert_select "tr[data-seq='0'] td.hb-turn-shared", false
    assert_select "tr[data-seq='1'] td.hb-turn-shared", 2
    assert_select "tr[data-test=heartbeat-event-action] td.hb-turn-shared", 2
  end

  test "[component] a shared turn in the Unlabeled group fades its later rows too" do
    first  = action(atomic_event_id: nil, seq: 0, source_turn_uuid: "turn-U",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    second = action(atomic_event_id: nil, seq: 1, source_turn_uuid: "turn-U",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    shared = Set.new([second.id])

    render partial: "heartbeat/event_table",
           locals: { event_rows: [], unlabeled: [first, second], pokemon_by_slug: {},
                     shared_turn_ids: shared }

    assert_select "tbody[data-test=heartbeat-unlabeled] tr[data-seq='0'] td.hb-turn-shared", false
    assert_select "tbody[data-test=heartbeat-unlabeled] tr[data-seq='1'] td.hb-turn-shared", 2
  end

  test "[component] the mascot column header now reads Agent" do
    render partial: "heartbeat/event_table",
           locals: { event_rows: [], unlabeled: [], pokemon_by_slug: {} }

    assert_select "thead th", text: "Agent"
    assert_select "thead th", text: "Pokémon", count: 0
  end

  test "[component] a span with an acting soul stacks the soul over the base mascot" do
    avi  = Agent.new(slug: "avi", name: "Avi", metadata: { "emoji" => "📋", "color" => "#FB7185" })
    ev   = event(seq: 0, mascot: "shellder", agent: "avi", closed_at: Time.current, outcome_slug: "reviewed")
    poke = Pokemon.new(slug: "shellder", name: "Shellder")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: { "shellder" => poke },
                     agents_by_slug: { "avi" => avi } }

    # the acting soul renders server-side (Nokogiri-visible) ON TOP
    assert_select "[data-test=agent-stack]"
    assert_select "[data-test=agent-soul][data-soul=avi]", text: /Avi/
    # the base session mascot renders BENEATH, inside the same stack
    assert_select "[data-test=agent-stack] [data-test=event-mascot]", text: /Shellder/
  end

  test "[component] a span with no acting soul renders just the base mascot (no stack)" do
    ev = event(seq: 0, mascot: "sandshrew", agent: nil, closed_at: Time.current, outcome_slug: "done")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "[data-test=agent-stack]", false
    assert_select "[data-test=agent-soul]", false
    assert_select "[data-test=event-mascot]", text: /Sandshrew/
  end

  test "[component] drill-down actions inherit their span's acting soul" do
    avi = Agent.new(slug: "avi", name: "Avi", metadata: { "emoji" => "📋" })
    ev  = event(seq: 0, mascot: "shellder", agent: "avi", closed_at: Time.current, outcome_slug: "reviewed")
    a1  = action(atomic_event_id: ev.id, seq: 0, mascot: "shellder", kind: "read")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1]]], unlabeled: [], pokemon_by_slug: {},
                     agents_by_slug: { "avi" => avi } }

    assert_select "tr[data-test=heartbeat-event-action] [data-test=agent-soul][data-soul=avi]"
  end

  test "[component] a span's existing grade markers render server-side from event_grades" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    grade = ActionGrade.create!(atomic_event: ev, grader: "alex", disposition: "good",
                                slug: "tight span with a clean outcome")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {},
                     event_grades: { ev.id => { "alex" => grade } } }

    # the Alex marker is server-rendered (Nokogiri-visible), carrying its slug
    assert_select "[data-test=event-grade-alex]"
    assert_includes rendered, "tight span with a clean outcome"
    # and the tbody carries the hydration data the Alpine row reads
    assert_select "tbody[data-test=heartbeat-event][data-alex-graded=true]"
  end
end
