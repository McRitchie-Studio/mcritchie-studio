require "test_helper"

# [integration] GET /alex/heartbeat/activities — the cross-session All Activities page. Every
# narrated AgentActivity across ALL sessions, newest-first, paginated 100 per page.
# Reuses the per-session activity table + drawer; there is no per-session "Unlabeled" group
# here. Read-only meta surface, like the per-session heartbeat — no auth.
class HeartbeatAllSpansTest < ActionDispatch::IntegrationTest
  def span(session: "sess-A", at: Time.current, **attrs)
    AgentActivity.create!({ session_id: session, category: "Explore", reason_slug: "find issue with api",
                          opened_at: at, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  test "routes to the all_activities action and keeps the old spans alias" do
    assert_equal "/alex/heartbeat/activities", heartbeat_all_activities_path
    assert_equal "/alex/heartbeat/spans", heartbeat_all_spans_path
    assert_routing "/alex/heartbeat/activities", controller: "heartbeat", action: "all_activities"
    assert_recognizes({ controller: "heartbeat", action: "all_activities" }, "/alex/heartbeat/spans")
  end

  test "renders activities from every session, newest-first, without auth" do
    span(session: "sess-A", reason_slug: "older span here", at: 5.minutes.ago)
    span(session: "sess-B", reason_slug: "newer span here", at: 1.minute.ago)

    get heartbeat_all_activities_path

    assert_response :success
    assert_select "[data-test=heartbeat-all-activities]"
    assert_select "table[data-test=heartbeat-event-table]"
    assert_select "tbody[data-test=heartbeat-event]", 2
    # cross-session: both sessions' activities appear, newest (sess-B) before oldest (sess-A)
    body = response.body
    assert_operator body.index("newer span here"), :<, body.index("older span here")
  end

  test "paginates 100 spans per page with a working older/newer pager" do
    # 101 spans -> two pages (100 + 1)
    101.times { |i| span(session: "s", reason_slug: "span number #{i}", seq: i, at: i.minutes.ago) }

    get heartbeat_all_activities_path

    assert_response :success
    assert_select "tbody[data-test=heartbeat-event]", 100
    assert_select "[data-test=hb-pager]"
    # newest page has an "Older" link forward and no "Newer" link back
    assert_select "a[data-test=hb-pager-next][href=?]", heartbeat_all_activities_path(page: 2)
    assert_select "a[data-test=hb-pager-prev]", false

    get heartbeat_all_activities_path(page: 2)

    assert_response :success
    assert_select "tbody[data-test=heartbeat-event]", 1
    assert_select "a[data-test=hb-pager-prev][href=?]", heartbeat_all_activities_path(page: 1)
    assert_select "a[data-test=hb-pager-next]", false
  end

  test "carries the heartbeat navbar with a link back to the per-session view" do
    span

    get heartbeat_all_activities_path

    assert_response :success
    assert_select "a[href=?][data-test=hb-nav-all-spans]", heartbeat_all_activities_path
    assert_select "a[href=?][data-test=hb-nav-session]", alex_heartbeat_path
  end

  test "renders no Unlabeled group even when null-span actions exist (single group per view)" do
    ev = span
    # an orphan action (no span) exists, but All Spans is span-centric: it must not
    # surface a cross-session Unlabeled group
    AgentAction.create!(session_id: "sess-A", kind: "boot", outcome: "ok", actor: "harness",
                         seq: 0, occurred_at: Time.current, agent_activity_id: nil,
                         event_slug: "orphan boot step")
    AgentAction.create!(session_id: "sess-A", kind: "grep", outcome: "ok", actor: "agent",
                         seq: 1, occurred_at: Time.current, agent_activity_id: ev.id)

    get heartbeat_all_activities_path

    assert_response :success
    assert_select "tbody[data-test=heartbeat-unlabeled]", false
  end

  test "the span table opts out of the app-wide sticky header clone" do
    span

    get heartbeat_all_activities_path

    assert_response :success
    # The heartbeat table pins its own thead th (position:sticky inside .hb-scroll).
    # Without this opt-out, sticky_table_header.js clones the thead into an unstyled
    # body-level bar the moment the in-flow thead box scrolls under the navbar —
    # a doubled, unstyled header. The attribute is the contract that prevents it.
    assert_select "table[data-test=heartbeat-event-table][data-sticky-table-header=false]"
  end

  test "renders a friendly empty state when nothing has been captured" do
    get heartbeat_all_activities_path

    assert_response :success
    assert_select "[data-test=heartbeat-empty]"
  end

  test "a graded span shows its inline quick-grade radios on the All Spans page too" do
    ev = span(closed_at: 1.minute.ago, outcome_slug: "done")

    get heartbeat_all_activities_path

    assert_response :success
    assert_select "form[data-test=event-inline-grade][action=?]", heartbeat_activity_grade_path(ev), 2
  end

  # An optional ?session_id= narrows the cross-session list to one session; the
  # default (no param) still spans every session (covered above).
  test "filters to a single session when ?session_id= is given" do
    span(session: "sess-A", reason_slug: "activity in session A", at: 2.minutes.ago)
    span(session: "sess-B", reason_slug: "activity in session B", at: 1.minute.ago)

    get heartbeat_all_activities_path(session_id: "sess-A")

    assert_response :success
    assert_select "tbody[data-test=heartbeat-event]", 1
    assert_match "activity in session A", response.body
    assert_no_match(/activity in session B/, response.body)
  end

  # The picker reuses the per-session mascot labels; on this page it leads with a
  # blank "All sessions" option because the default view is unfiltered.
  test "renders the session picker with an All sessions default and mascot labels" do
    a = "e2f6eb27-415c-4f3d-81c4-5bdf64064904"
    b = "3618cc6d-6176-43d6-8cc0-45b6fcfffaa"
    Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", types: %w[grass], generation: 1)
    Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", types: %w[fire], generation: 1)
    SessionMascot.create!(session_id: a, mascot_slug: "bulbasaur")
    SessionMascot.create!(session_id: b, mascot_slug: "charizard")
    span(session: a, reason_slug: "span in session A", at: 2.minutes.ago)
    span(session: b, reason_slug: "span in session B", at: 1.minute.ago)

    get heartbeat_all_activities_path

    assert_response :success
    # the picker posts back to the same cross-session page
    assert_select "form[action=?] select.hb-sel", heartbeat_all_activities_path
    # a blank "All sessions" option leads (the unfiltered default)...
    assert_select "select.hb-sel option[value='']", text: "All sessions"
    # ...followed by each session's mascot-labelled option
    assert_select "select.hb-sel option[value=?]", a, text: "Bulbasaur · e2f6eb27"
    assert_select "select.hb-sel option[value=?]", b, text: "Charizard · 3618cc6d"
  end

  test "marks the active session as selected in the picker" do
    a = "e2f6eb27-415c-4f3d-81c4-5bdf64064904"
    b = "3618cc6d-6176-43d6-8cc0-45b6fcfffaa"
    span(session: a, reason_slug: "span A", at: 2.minutes.ago)
    span(session: b, reason_slug: "span B", at: 1.minute.ago)

    get heartbeat_all_activities_path(session_id: a)

    assert_response :success
    assert_select "select.hb-sel option[value=?][selected]", a
  end

  test "the pager preserves the active session filter across pages" do
    # 101 spans in the filtered session -> two pages; a stray span in another
    # session must leak into neither page nor the pager links.
    101.times { |i| span(session: "sess-A", reason_slug: "A span #{i}", seq: i, at: i.minutes.ago) }
    span(session: "sess-B", reason_slug: "B span here", at: 200.minutes.ago)

    get heartbeat_all_activities_path(session_id: "sess-A")

    assert_response :success
    assert_select "tbody[data-test=heartbeat-event]", 100
    assert_select "a[data-test=hb-pager-next][href=?]",
                  heartbeat_all_activities_path(page: 2, session_id: "sess-A")

    get heartbeat_all_activities_path(page: 2, session_id: "sess-A")

    assert_response :success
    assert_select "tbody[data-test=heartbeat-event]", 1
    assert_select "a[data-test=hb-pager-prev][href=?]",
                  heartbeat_all_activities_path(page: 1, session_id: "sess-A")
    assert_no_match(/B span here/, response.body)
  end
end
