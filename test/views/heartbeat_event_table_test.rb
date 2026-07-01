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
end
