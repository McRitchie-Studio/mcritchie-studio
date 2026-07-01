require "test_helper"

# [integration] GET /alex/heartbeat — two faces chosen by the session_id param:
# with NO session_id, the GLOBAL FEED (every narrated span across all sessions,
# newest-first) whose rows drill into a session; with a session_id, that session's
# DETAIL trajectory — agent-narrated EVENT SPANS as the primary rows, read from
# AtomicEvent.for_session(...).chronological (oldest -> newest), the raw
# AtomicActions attributed to each span (atomic_event_id) rolling up as a read-only
# drill-down (a null atomic_event_id falls into "Unlabeled"). Read-only meta
# surface, so it needs no auth.
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

    get alex_heartbeat_path(session_id: "sess-A")

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

  test "the per-session detail view presents spans oldest to newest by opened_at" do
    # Insert out of order; the session detail view must present them oldest first
    # (a single session still reads as a trajectory — the feed is the newest-first one).
    event(seq: 2, reason_slug: "third span opened", at: 1.minute.ago, closed_at: 30.seconds.ago)
    event(seq: 0, reason_slug: "first span opened", at: 3.minutes.ago, closed_at: 2.minutes.ago)
    event(seq: 1, reason_slug: "second span opened", at: 2.minutes.ago, closed_at: 90.seconds.ago)

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    body = response.body
    assert_operator body.index("first span opened"),  :<, body.index("second span opened")
    assert_operator body.index("second span opened"), :<, body.index("third span opened")
  end

  test "with no session_id renders the global feed of every session, newest-first" do
    event(session: "sess-A", reason_slug: "older span in A", at: 5.minutes.ago,
          closed_at: 4.minutes.ago, outcome_slug: "did A")
    event(session: "sess-B", reason_slug: "newer span in B", at: 1.minute.ago,
          closed_at: 30.seconds.ago, outcome_slug: "did B")

    get alex_heartbeat_path

    assert_response :success
    assert_select "table[data-test=heartbeat-feed]"
    # both sessions share one feed
    assert_match "older span in A", response.body
    assert_match "newer span in B", response.body
    # newest span sits on top
    assert_operator response.body.index("newer span in B"), :<, response.body.index("older span in A")
    # each row exposes an "open" button drilling into that session's detail view
    assert_select "a[data-test=heartbeat-feed-open][href=?]", alex_heartbeat_path(session_id: "sess-A")
    assert_select "a[data-test=heartbeat-feed-open][href=?]", alex_heartbeat_path(session_id: "sess-B")
  end

  test "a feed open button drills into that session's detail view, not the feed" do
    a = event(session: "sess-A", reason_slug: "span in session A")
    action(event: a, session: "sess-A")
    event(session: "sess-B", reason_slug: "span in session B")

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    # the drilled-in view is the per-session detail table, and the feed is gone
    assert_select "table[data-test=heartbeat-event-table]"
    assert_select "table[data-test=heartbeat-feed]", false
    # scoped to the one session, with a link back to the all-sessions feed
    assert_match "span in session A", response.body
    assert_no_match(/span in session B/, response.body)
    assert_select "a[data-test=heartbeat-all-sessions][href=?]", alex_heartbeat_path
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

  test "the event row rolls up its actions' tokens, cost, model, and mascot" do
    ev = event(seq: 0, category: "Explore", reason_slug: "find the capture seam",
               mascot: "snorlax", outcome_slug: "found it", closed_at: 1.minute.ago, at: 3.minutes.ago)
    action(event: ev, seq: 0, at: 3.minutes.ago, model: "claude-opus-4-8", tokens_in: 9400, tokens_out: 360, cost: 0.05)
    action(event: ev, seq: 1, at: 2.minutes.ago, model: "claude-opus-4-8", tokens_in: 6800, tokens_out: 2400, cost: 0.09)

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    assert_select "[data-test=event-tokens]", text: "16.2k/2.8k"
    assert_select "[data-test=event-cost]", text: "$0.1400"
    assert_select "[data-test=event-model]", text: "opus-4-8"
    assert_select "[data-test=event-mascot]", text: /Snorlax/
    assert_select "[data-test=event-status]", text: "done"
  end

  test "a turn's repeated tool-calls fade their tokens and cost cells end-to-end" do
    # One assistant turn, two tool-calls: both carry the turn's usage, so the second
    # renders IDENTICAL tokens/cost. The controller flags it session-wide and the view
    # fades that row's tokens+cost cells while the first (primary) keeps full color.
    ev = event(seq: 0, category: "Edit", reason_slug: "edit the view code",
               outcome_slug: "done", closed_at: 1.minute.ago, at: 3.minutes.ago)
    action(event: ev, seq: 0, at: 3.minutes.ago, source_turn_uuid: "turn-A",
           tokens_in: 9400, tokens_out: 360, cost: 0.05)
    action(event: ev, seq: 1, at: 2.minutes.ago, source_turn_uuid: "turn-A",
           tokens_in: 9400, tokens_out: 360, cost: 0.05)

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    assert_select "tr[data-seq='0'] td.hb-turn-shared", false
    assert_select "tr[data-seq='1'] td.hb-turn-shared", 2
    # the faded cells carry the inherit tooltip (assert_select decodes the entity)
    assert_select "td.hb-turn-shared[title=?]", "shared with this turn's first action", 2
    # totals stay DEDUPED + unchanged — the span still rolls the turn up once
    assert_select "[data-test=event-tokens]", text: "9.4k/360"
    assert_select "[data-test=event-cost]", text: "$0.0500"
  end

  test "each span row exposes a grade affordance into the span-grade drawer" do
    ev = event(seq: 0, closed_at: 1.minute.ago, outcome_slug: "done")

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    assert_select "[data-test=event-grade-open]"
    assert_match heartbeat_event_feedback_path(ev), response.body
  end

  test "the span-grade drawer body loads both span editors posting to the E2 endpoint" do
    ev = event(seq: 0, closed_at: 1.minute.ago, outcome_slug: "done")
    action(event: ev, seq: 0, model: "claude-opus-4-8", tokens_in: 9400, tokens_out: 360, cost: 0.05)

    get heartbeat_event_feedback_path(ev)

    assert_response :success
    assert_select "turbo-frame#hb-drawer"
    assert_select "form[data-test=span-grade-form]", 2
    assert_select "form[action=?]", heartbeat_event_grade_path(ev), 2
  end

  test "a graded span renders its grade marker server-side on the next load" do
    ev = event(seq: 0, reason_slug: "narrate this span well", closed_at: 1.minute.ago, outcome_slug: "done")

    # grade the span through E2, exactly as the drawer's fetch does
    post heartbeat_event_grade_path(ev),
         params: { grader: "alex", disposition: "good", slug: "clean span with a sharp outcome" }
    assert_response :success

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    assert_select "tbody[data-test=heartbeat-event][data-alex-graded=true]"
    assert_match "clean span with a sharp outcome", response.body
  end
end
