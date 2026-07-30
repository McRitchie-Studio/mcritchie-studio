require "test_helper"

# [integration] GET /agents/activities — the reimagined cross-session activity feed.
# Every narrated AgentActivity across ALL sessions, newest-first, with its raw actions
# (also newest-first) drilled down underneath and inline Alex/McRitchie grade cells on
# BOTH. An optional ?sessions= (comma list) narrows to a multi-select of sessions. A
# read-only meta surface (no auth), grading through the existing heartbeat endpoints.
class AgentsActivitiesTest < ActionDispatch::IntegrationTest
  def activity(session: "sess-A", at: Time.current, **attrs)
    AgentActivity.create!({ session_id: session, category: "Explore", reason_slug: "find issue with api",
                            opened_at: at, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  def action(activity_rec, session: "sess-A", at: Time.current, **attrs)
    AgentAction.create!({ session_id: session, kind: "grep", outcome: "ok", actor: "agent",
                          seq: attrs.fetch(:seq, 0), occurred_at: at, agent_activity_id: activity_rec&.id,
                          event_slug: "did a thing", input: '{"command":"grep foo"}' }.merge(attrs))
  end

  test "routes /agents/activities to the collection action, not agents#show" do
    assert_equal "/agents/activities", activities_agents_path
    assert_routing "/agents/activities", controller: "agents", action: "activities"
  end

  test "renders activities from every session, newest-first, without auth" do
    activity(session: "sess-A", reason_slug: "older activity here", at: 5.minutes.ago)
    activity(session: "sess-B", reason_slug: "newer activity here", at: 1.minute.ago)

    get activities_agents_path

    assert_response :success
    assert_select "[data-test=agents-activities]"
    assert_select "table[data-test=agents-activities-table]"
    assert_select "tbody[data-test=aa-activity]", 2
    body = response.body
    assert_operator body.index("newer activity here"), :<, body.index("older activity here")
  end

  test "subscribes to the live agents_activities stream and gives rows stable dom ids" do
    ev = activity(reason_slug: "a live activity")
    act = action(ev, event_slug: "a live action")

    get activities_agents_path

    assert_response :success
    # the turbo-cable stream source the browser subscribes through for live updates
    assert_select "turbo-cable-stream-source"
    # stable ids so ActivitiesBroadcaster can target the tbody (it re-renders the whole
    # tbody on activity/action updates); each turn row also carries its own stable id
    assert_select "tbody#aa-activity-#{ev.id}"
    assert_select "tr#aa-turn-solo-#{act.id}"
    # the thead insert-after target for new activities
    assert_select "thead#aa-activities-head"
  end

  test "filtered pages subscribe to session-scoped streams instead of the global stream" do
    activity(session: "sess-A", reason_slug: "visible activity")
    activity(session: "sess-B", reason_slug: "hidden activity")

    get activities_agents_path(sessions: "sess-A")

    assert_response :success
    assert_includes response.body, Turbo::StreamsChannel.signed_stream_name("agents_activities:session:sess-A")
    refute_includes response.body, Turbo::StreamsChannel.signed_stream_name("agents_activities")
  end

  test "wraps the feed in a turbo-frame so filter/pager clicks refresh in the background" do
    ev = activity(reason_slug: "a framed activity")

    get activities_agents_path

    assert_response :success
    # the whole feed lives in an advancing turbo-frame; a filter/pager link inside it
    # swaps just the frame (no full reload) and the url advances
    assert_select "turbo-frame#aa-activities-frame[data-turbo-action=advance]"
    assert_select "turbo-frame#aa-activities-frame table[data-test=agents-activities-table]"
    assert_select "turbo-frame#aa-activities-frame [data-test=aa-filter]"
    assert_select "turbo-frame#aa-activities-frame tbody#aa-activity-#{ev.id}"
    assert_select "turbo-frame#aa-activities-frame turbo-cable-stream-source"
    # the in-frame nav links no longer opt out of turbo (they navigate the frame)
    assert_select "a[data-test=aa-filter-session][data-turbo=false]", false
    assert_select "nav[data-test=aa-pager] a[data-turbo=false]", false
    # a real navigation away (Deployments) still bypasses turbo
    assert_select "a[href=?][data-turbo=false]", deployments_path
  end

  test "drills the raw actions under an activity, newest-first" do
    ev = activity(reason_slug: "an activity with actions")
    action(ev, seq: 0, at: 3.minutes.ago, event_slug: "the older action")
    action(ev, seq: 1, at: 1.minute.ago, event_slug: "the newer action")

    get activities_agents_path

    assert_response :success
    assert_select "tr[data-test=aa-turn]", 2, "two solo turns (no shared source_turn_uuid) → two turn rows"
    body = response.body
    assert_operator body.index("the newer action"), :<, body.index("the older action")
  end

  # [integration] Performance guard: the feed loads its per-action drill-down through
  # AgentAction.for_activity_feed, which drops the wide `output` blob (the captured
  # tool RESULT the page never renders). The rendered rows must be identical — the
  # action's input still surfaces (preview + tooltip) — while the output never rides
  # along in the payload. This is the query-shape optimization behind the heaviest
  # PROD page (p95 ~1779ms), asserted at the behaviour boundary.
  test "renders the action input but never loads the heavy output blob into the feed" do
    ev = activity(reason_slug: "an activity carrying a heavy action")
    output_sentinel = "HEAVY-OUTPUT-BLOB-#{'z' * 4000}"
    action(ev, event_slug: "a heavy action", kind: "read",
           input: '{"path":"THE-INPUT-SENTINEL"}', output: output_sentinel)

    get activities_agents_path

    assert_response :success
    # The rendered output is unchanged: the action's turn row and its input preview
    # (the tooltip carries the full input) both still render.
    assert_select "tr[data-test=aa-turn]"
    assert_select "[data-test=aa-turn-input]"
    assert_includes response.body, "THE-INPUT-SENTINEL", "the feed still renders the action input"
    # The wide output blob is never selected, so it never reaches the page.
    assert_not_includes response.body, output_sentinel,
                        "the feed must not load or render the action's output column"
  end

  test "shows the empty-actions placeholder for an activity with no actions" do
    activity(reason_slug: "a lonely activity")

    get activities_agents_path

    assert_response :success
    assert_select "tr.aa-emptyrow"
  end

  test "renders inline grade cells for both the activity and its actions" do
    ev = activity(reason_slug: "gradable activity")
    act = action(ev)

    get activities_agents_path

    assert_response :success
    # activity-level grade forms post to the activity grade endpoint
    assert_select "form[data-test=aa-activity-grade-form-alex][action=?]", heartbeat_activity_grade_path(ev)
    assert_select "form[data-test=aa-activity-grade-form-mcr][action=?]", heartbeat_activity_grade_path(ev)
    # action-level grade forms post to the action grade endpoint
    assert_select "form[data-test=aa-action-grade-form-alex][action=?]", heartbeat_grade_path(act)
    assert_select "form[data-test=aa-action-grade-form-mcr][action=?]", heartbeat_grade_path(act)
  end

  test "an existing activity grade renders its note slug server-side" do
    ev = activity(reason_slug: "already graded activity")
    ActionGrade.create!(agent_activity: ev, grader: "alex", disposition: "good", slug: "solid narration here indeed")

    get activities_agents_path

    assert_response :success
    assert_select "[data-test=aa-activity-note-alex]", text: /solid narration here indeed/
  end

  test "filters to a single session with ?sessions=" do
    activity(session: "sess-A", reason_slug: "activity in session A", at: 2.minutes.ago)
    activity(session: "sess-B", reason_slug: "activity in session B", at: 1.minute.ago)

    get activities_agents_path(sessions: "sess-A")

    assert_response :success
    assert_select "tbody[data-test=aa-activity]", 1
    assert_match "activity in session A", response.body
    assert_no_match(/activity in session B/, response.body)
    assert_select "[data-test=aa-active-filters]"
  end

  test "shows the filtered cost total before the activity count when under 100 activities" do
    activity(session: "sess-A", reason_slug: "priced activity one", cost: 0.10)
    activity(session: "sess-A", reason_slug: "priced activity two", cost: 0.025)
    activity(session: "sess-B", reason_slug: "hidden priced activity", cost: 0.50)

    get activities_agents_path(sessions: "sess-A")

    assert_response :success
    assert_select "[data-test=aa-filtered-cost] b", text: "$0.1250"
    assert_select "[data-test=aa-activity-total] b", text: "2"
    assert_operator response.body.index('data-test="aa-filtered-cost"'),
                    :<, response.body.index('data-test="aa-activity-total"')
  end

  test "hides the filtered cost total when the activity count reaches 100" do
    100.times { |i| activity(session: "sess-A", reason_slug: "activity number #{i}", seq: i, cost: 0.01) }

    get activities_agents_path(sessions: "sess-A")

    assert_response :success
    assert_select "[data-test=aa-filtered-cost]", false
    assert_select "[data-test=aa-activity-total] b", text: "100"
  end

  test "the active-filters row always renders (reserves space) even with no filter" do
    activity(session: "sess-A", reason_slug: "some activity here")

    get activities_agents_path

    assert_response :success
    # present even unfiltered so adding a filter never jumps the table
    assert_select "[data-test=aa-active-filters]", text: /Showing all sessions/
    assert_select "[data-test=aa-active-filter]", false
  end

  test "multi-selects sessions (OR) with a comma-joined ?sessions=" do
    activity(session: "sess-A", reason_slug: "activity in session A", at: 3.minutes.ago)
    activity(session: "sess-B", reason_slug: "activity in session B", at: 2.minutes.ago)
    activity(session: "sess-C", reason_slug: "activity in session C", at: 1.minute.ago)

    get activities_agents_path(sessions: "sess-A,sess-B")

    assert_response :success
    assert_select "tbody[data-test=aa-activity]", 2
    assert_match "activity in session A", response.body
    assert_match "activity in session B", response.body
    assert_no_match(/activity in session C/, response.body)
  end

  test "the main feed carries the lazy filter shell but not the heavy session list" do
    a = "aaaaaaaa-1111-2222-3333-444444444444"
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1)
    SessionMascot.create!(session_id: a, mascot_slug: "snorlax")
    activity(session: a, reason_slug: "activity here", at: 1.minute.ago)

    get activities_agents_path

    assert_response :success
    # the panel shell + its lazy frame render, but the session list itself does NOT ride
    # the main feed render (it lazy-loads via activities_filter) — keeping the heavy
    # cross-session scan off this hot path.
    assert_select "[data-test=aa-filter]"
    assert_select "turbo-frame#aa-filter-frame[src][loading=lazy]"
    assert_select "a[data-test=aa-filter-session]", false
  end

  test "the lazy filter endpoint lists every session with its Pokémon name inside the frame" do
    a = "aaaaaaaa-1111-2222-3333-444444444444"
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1)
    SessionMascot.create!(session_id: a, mascot_slug: "snorlax")
    activity(session: a, reason_slug: "activity here", at: 1.minute.ago)

    get activities_filter_agents_path

    assert_response :success
    assert_select "turbo-frame#aa-filter-frame a[data-test=aa-filter-session][data-session-id=?]", a, text: /Snorlax/
    # the session toggle link targets the FEED frame so a click filters the whole feed
    assert_select "a[data-test=aa-filter-session][data-turbo-frame=aa-activities-frame]"
  end

  test "falls back to the activity mascot when a session has no SessionMascot row" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1)
    activity(session: "no-mascot-sess", reason_slug: "activity here", mascot: "snorlax", at: 1.minute.ago)

    get activities_filter_agents_path

    assert_response :success
    assert_select "a[data-test=aa-filter-session]", text: /Snorlax/
  end

  test "orders the filter sidebar newest-active first with each session's last-active time" do
    activity(session: "sess-stale", reason_slug: "old activity", at: 3.hours.ago)
    activity(session: "sess-fresh", reason_slug: "recent activity", at: 2.minutes.ago)

    get activities_filter_agents_path

    assert_response :success
    body = response.body
    # the freshly-active session is listed above the stale one in the sidebar
    assert_operator body.index('data-session-id="sess-fresh"'),
                    :<, body.index('data-session-id="sess-stale"')
    # and each row surfaces a compact recency label so the order reads at a glance
    assert_select "a[data-test=aa-filter-session][data-session-id=?] [data-test=aa-fs-ago]",
                  "sess-fresh", text: "2m ago"
  end

  test "keeps an activity-only session (no captured actions) in the filter sidebar" do
    activity(session: "activity-only-sess", reason_slug: "narrated but no tool calls", at: 1.minute.ago)

    get activities_filter_agents_path

    assert_response :success
    # a session that narrated an activity but captured zero AgentActions must not be
    # dropped — the sidebar keys on the UNION of action + activity time, not actions alone.
    assert_select "a[data-test=aa-filter-session][data-session-id=?]", "activity-only-sess"
  end

  test "the active-filter chip names the selected session server-side (no full scan)" do
    a = "bbbbbbbb-1111-2222-3333-444444444444"
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1)
    SessionMascot.create!(session_id: a, mascot_slug: "snorlax")
    activity(session: a, reason_slug: "activity in the selected session", at: 1.minute.ago)

    get activities_agents_path(sessions: a)

    assert_response :success
    # the top active-filter chip resolves the SELECTED session's Pokémon name via the
    # cheap id-scoped selected_session_chips — no lazy sidebar needed for the chip.
    assert_select "[data-test=aa-active-filter]", text: /Snorlax/
  end

  test "the live feed hooks the action-count pulse on a real count change" do
    activity(reason_slug: "a live activity")

    get activities_agents_path

    assert_response :success
    # The pulse ANIMATION is now defined in the compiled stylesheet (heartbeat.css,
    # de-inlined from the old inline <style> — asserted by HeartbeatStylesDeinlinedTest),
    # so it is no longer in response.body. What the page still ships inline is the
    # live-fx HOOK: it adds .aa-count-pulse when a count actually changes (a new action)
    # and holds it for the 8s (PULSE_MS) run the @keyframes expects.
    assert_includes response.body, %q{node.classList.add("aa-count-pulse")}
    assert_includes response.body, "PULSE_MS = 8000"
  end

  test "renders a friendly empty state when nothing is captured, and a filtered empty state" do
    get activities_agents_path
    assert_response :success
    assert_select "[data-test=aa-empty]"

    activity(session: "sess-A", reason_slug: "only in A")
    get activities_agents_path(sessions: "sess-Z")
    assert_response :success
    assert_select "[data-test=aa-empty]"
    assert_no_match(/only in A/, response.body)
  end

  test "paginates 25 per page and threads the sessions filter through the pager" do
    26.times { |i| activity(session: "sess-A", reason_slug: "activity number #{i}", seq: i, at: i.minutes.ago) }
    activity(session: "sess-B", reason_slug: "stray B activity", at: 500.minutes.ago)

    get activities_agents_path(sessions: "sess-A")

    assert_response :success
    assert_select "tbody[data-test=aa-activity]", 25
    assert_select "a[data-test=aa-pager-next][href=?]", activities_agents_path(page: 2, sessions: "sess-A")
    assert_select "a[data-test=aa-pager-prev]", false
    assert_no_match(/stray B activity/, response.body)

    get activities_agents_path(page: 2, sessions: "sess-A")

    assert_response :success
    assert_select "tbody[data-test=aa-activity]", 1
    assert_select "a[data-test=aa-pager-prev][href=?]", activities_agents_path(page: 1, sessions: "sess-A")
  end

  # The inline action-grade × button clears that grader's grade — the new action-level
  # analogue of the activity clear. JSON, exercised by the aa-* grade cell's clearGrade.
  test "clears an action grade via intent=clear on the action grade endpoint" do
    ev = activity
    act = action(ev)
    ActionGrade.create!(agent_action: act, grader: "alex", disposition: "not", slug: "needs a rethink here")

    assert_equal 1, ActionGrade.for_action(act).by_grader("alex").count

    post heartbeat_grade_path(act), params: { grader: "alex", intent: "clear" }, as: :json

    assert_response :success
    assert_equal 0, ActionGrade.for_action(act).by_grader("alex").count
    assert JSON.parse(response.body)["cleared"]
  end

  test "[integration] the drill-down collapses fan-out to turn rows with a reconciling total" do
    act = activity(session: "turn-grp", reason_slug: "build the thing",
                   tokens_in: 45_062, tokens_out: 10_161, model: "claude-opus-4-8", cost: 1.29)
    # a fan-out turn (t1: 2 tools, one source_turn_uuid) + a solo turn (t2)
    action(act, session: "turn-grp", seq: 0, kind: "bash", source_turn_uuid: "t1", tokens_in: 4262, tokens_out: 418, summary: "preflight")
    action(act, session: "turn-grp", seq: 1, kind: "read", source_turn_uuid: "t1", tokens_in: 4262, tokens_out: 418, summary: "read helper")
    action(act, session: "turn-grp", seq: 2, kind: "read", source_turn_uuid: "t2", tokens_in: 526,  tokens_out: 326, summary: "read test")

    get activities_agents_path
    assert_response :success

    # the fan-out (t1's 2 tools) collapses to ONE turn row with the summaries joined
    # (newest-first display order within the turn: seq 1 "read helper" before seq 0 "preflight")
    assert_select "[data-test=aa-turn-summary]", text: /read helper · preflight/
    # the OLD per-action rows are gone (replaced by turn rows)
    assert_select "[data-test=aa-action]", 0
    # the reasoning + prose line and the reconciling TOTAL render for this span
    assert_select "tr#aa-reasoning-#{act.id} [data-test=aa-reasoning-label]", text: /reasoning \+ prose/
    assert_select "tr#aa-total-#{act.id} [data-test=aa-total-label]", text: "TOTAL"
  end
end
