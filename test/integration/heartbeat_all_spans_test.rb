require "test_helper"

# [integration] GET /alex/heartbeat/spans — the cross-session All Spans page. Every
# narrated AtomicEvent span across ALL sessions, newest-first, paginated 100 per page.
# Reuses the per-session span table + drawer; there is no per-session "Unlabeled" group
# here. Read-only meta surface, like the per-session heartbeat — no auth.
class HeartbeatAllSpansTest < ActionDispatch::IntegrationTest
  def span(session: "sess-A", at: Time.current, **attrs)
    AtomicEvent.create!({ session_id: session, category: "Explore", reason_slug: "find issue with api",
                          opened_at: at, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  test "routes to the all_spans action" do
    assert_equal "/alex/heartbeat/spans", heartbeat_all_spans_path
    assert_routing "/alex/heartbeat/spans", controller: "heartbeat", action: "all_spans"
  end

  test "renders spans from every session, newest-first, without auth" do
    span(session: "sess-A", reason_slug: "older span here", at: 5.minutes.ago)
    span(session: "sess-B", reason_slug: "newer span here", at: 1.minute.ago)

    get heartbeat_all_spans_path

    assert_response :success
    assert_select "[data-test=heartbeat-all-spans]"
    assert_select "table[data-test=heartbeat-event-table]"
    assert_select "tbody[data-test=heartbeat-event]", 2
    # cross-session: both sessions' spans appear, newest (sess-B) before oldest (sess-A)
    body = response.body
    assert_operator body.index("newer span here"), :<, body.index("older span here")
  end

  test "paginates 100 spans per page with a working older/newer pager" do
    # 101 spans -> two pages (100 + 1)
    101.times { |i| span(session: "s", reason_slug: "span number #{i}", seq: i, at: i.minutes.ago) }

    get heartbeat_all_spans_path

    assert_response :success
    assert_select "tbody[data-test=heartbeat-event]", 100
    assert_select "[data-test=hb-pager]"
    # newest page has an "Older" link forward and no "Newer" link back
    assert_select "a[data-test=hb-pager-next][href=?]", heartbeat_all_spans_path(page: 2)
    assert_select "a[data-test=hb-pager-prev]", false

    get heartbeat_all_spans_path(page: 2)

    assert_response :success
    assert_select "tbody[data-test=heartbeat-event]", 1
    assert_select "a[data-test=hb-pager-prev][href=?]", heartbeat_all_spans_path(page: 1)
    assert_select "a[data-test=hb-pager-next]", false
  end

  test "carries the heartbeat navbar with a link back to the per-session view" do
    span

    get heartbeat_all_spans_path

    assert_response :success
    assert_select "a[href=?][data-test=hb-nav-all-spans]", heartbeat_all_spans_path
    assert_select "a[href=?][data-test=hb-nav-session]", alex_heartbeat_path
  end

  test "renders no Unlabeled group even when null-span actions exist (single group per view)" do
    ev = span
    # an orphan action (no span) exists, but All Spans is span-centric: it must not
    # surface a cross-session Unlabeled group
    AtomicAction.create!(session_id: "sess-A", kind: "boot", outcome: "ok", actor: "harness",
                         seq: 0, occurred_at: Time.current, atomic_event_id: nil,
                         event_slug: "orphan boot step")
    AtomicAction.create!(session_id: "sess-A", kind: "grep", outcome: "ok", actor: "agent",
                         seq: 1, occurred_at: Time.current, atomic_event_id: ev.id)

    get heartbeat_all_spans_path

    assert_response :success
    assert_select "tbody[data-test=heartbeat-unlabeled]", false
  end

  test "renders a friendly empty state when nothing has been captured" do
    get heartbeat_all_spans_path

    assert_response :success
    assert_select "[data-test=heartbeat-empty]"
  end

  test "a graded span shows its inline quick-grade radios on the All Spans page too" do
    ev = span(closed_at: 1.minute.ago, outcome_slug: "done")

    get heartbeat_all_spans_path

    assert_response :success
    assert_select "form[data-test=event-inline-grade][action=?]", heartbeat_event_grade_path(ev), 2
  end
end
