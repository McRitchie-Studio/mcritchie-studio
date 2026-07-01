require "test_helper"

# [integration] GET /alex/heartbeat — the Alex avenue now renders agent-narrated
# EVENT SPANS as the primary rows, read from AtomicEvent.for_session(...).chronological
# (oldest -> newest). The raw AtomicActions attributed to each span (atomic_event_id)
# roll up underneath as a read-only drill-down; actions with a null atomic_event_id
# fall into the "Unlabeled" group. Read-only meta surface, so it needs no auth.
class AlexHeartbeatTest < ActionDispatch::IntegrationTest
  def event(session: "sess-A", at: Time.current, **attrs)
    AtomicEvent.create!({ session_id: session, category: "Explore", reason_slug: "find issue with api",
                          opened_at: at, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  def action(event: nil, session: "sess-A", at: Time.current, **attrs)
    AtomicAction.create!({ session_id: session, kind: "grep", outcome: "ok", actor: "agent",
                           seq: attrs.fetch(:seq, 0), occurred_at: at,
                           atomic_event_id: event&.id }.merge(attrs))
  end

  test "alex_heartbeat_path routes to the trajectory view, repointed off the launcher placeholder" do
    assert_equal "/alex/heartbeat", alex_heartbeat_path
    assert_routing "/alex/heartbeat", controller: "heartbeat", action: "show"
  end

  test "renders event spans, rolling attributed actions under each, without auth" do
    explore = event(seq: 0, category: "Explore", reason_slug: "find issue with api",
                    outcome_slug: "found the nil-guard", closed_at: 1.minute.ago, at: 3.minutes.ago)
    action(event: explore, seq: 0, at: 3.minutes.ago, kind: "grep",
           event_slug: "Grep the capture seam", input: "grep -rn AtomicAction app/models")
    verify = event(seq: 1, category: "Verify", reason_slug: "run the unit suite",
                   outcome_slug: "green", closed_at: 30.seconds.ago, at: 90.seconds.ago)
    action(event: verify, seq: 1, at: 90.seconds.ago, kind: "bash", event_slug: "Run the tests")

    get alex_heartbeat_path

    assert_response :success
    assert_select "[data-test=heartbeat]"
    assert_select "table[data-test=heartbeat-event-table]"
    assert_select "tbody[data-test=heartbeat-event]", 2
    assert_select "tbody[data-test=heartbeat-event][data-category=Explore]"
    assert_select "tbody[data-test=heartbeat-event][data-category=Verify]"
    # the raw tool-calls roll up as a drill-down under their spans
    assert_select "tr[data-test=heartbeat-event-action]", 2
    assert_match "find issue with api", response.body
    assert_match "found the nil-guard", response.body
    assert_match "Grep the capture seam", response.body
  end

  test "an open span with no outcome renders the in-progress placeholder" do
    event(seq: 0, category: "Workflow", reason_slug: "certify and open the PR",
          outcome_slug: nil, closed_at: nil)

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    assert_select "[data-test=event-in-progress]"
    assert_match(/in progress/, response.body)
  end

  test "actions with a null atomic_event_id render in the Unlabeled group" do
    action(event: nil, seq: 0, kind: "boot", event_slug: "Unnarrated boot step")

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    assert_select "tbody[data-test=heartbeat-unlabeled]"
    assert_select "tbody[data-test=heartbeat-unlabeled] tr[data-test=heartbeat-event-action]", 1
    assert_match "Unnarrated boot step", response.body
  end

  test "presents spans oldest to newest by opened_at" do
    # Insert out of order; the view must present them oldest first.
    event(seq: 2, reason_slug: "third span opened", at: 1.minute.ago, closed_at: 30.seconds.ago)
    event(seq: 0, reason_slug: "first span opened", at: 3.minutes.ago, closed_at: 2.minutes.ago)
    event(seq: 1, reason_slug: "second span opened", at: 2.minutes.ago, closed_at: 90.seconds.ago)

    get alex_heartbeat_path

    assert_response :success
    body = response.body
    assert_operator body.index("first span opened"),  :<, body.index("second span opened")
    assert_operator body.index("second span opened"), :<, body.index("third span opened")
  end

  test "scopes to a session via the session_id param" do
    a = event(session: "sess-A", reason_slug: "session A span")
    action(event: a, session: "sess-A")
    b = event(session: "sess-B", reason_slug: "session B span")
    action(event: b, session: "sess-B")

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    assert_match "session A span", response.body
    assert_no_match(/session B span/, response.body)
  end

  test "keeps the grading drawer host for per-action grading" do
    e = event(seq: 0, closed_at: 1.minute.ago, outcome_slug: "done")
    action(event: e, seq: 0)

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    assert_select "aside[data-test=heartbeat-drawer]"
    assert_select "a[href=?]", alex_insights_path, text: /Insight Bank/
  end

  test "renders a friendly empty state when nothing has been captured" do
    get alex_heartbeat_path

    assert_response :success
    assert_select "[data-test=heartbeat-empty]"
  end
end
