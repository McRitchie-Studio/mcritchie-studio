require "test_helper"

# [component] the GLOBAL heartbeat feed partial — every narrated AtomicEvent across
# ALL sessions rendered as one lightweight, newest-first index. Each row carries its
# span's category, reason -> outcome, lifecycle status, owning session, and an "open"
# button drilling into that session's detail view. No per-action roll-up lives here
# (that is the per-session detail table); a truncated feed surfaces a notice.
class HeartbeatFeedTest < ActionView::TestCase
  def event(**attrs)
    AtomicEvent.create!({ session_id: "sess-A", category: "Explore", reason_slug: "find issue with api",
                          opened_at: Time.current, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  test "[component] renders one row per span with its session and an open button" do
    a = event(session_id: "sess-A", category: "Explore", reason_slug: "find issue with api",
              outcome_slug: "found the nil-guard", closed_at: Time.current, seq: 0)
    b = event(session_id: "sess-B", category: "Verify", reason_slug: "run the unit suite",
              outcome_slug: "green", closed_at: Time.current, seq: 0)

    render partial: "heartbeat/feed",
           locals: { feed_events: [b, a], pokemon_by_slug: {}, feed_truncated: false,
                     feed_total: 2, feed_limit: 200 }

    assert_select "table[data-test=heartbeat-feed]"
    assert_select "tr[data-test=heartbeat-feed-row]", 2
    assert_select ".hb-catchip", text: "Explore"
    assert_select ".hb-catchip", text: "Verify"
    assert_includes rendered, "find issue with api"
    assert_includes rendered, "found the nil-guard"
    # each row's open button points at that session's detail view
    assert_select "a[data-test=heartbeat-feed-open][href=?]", alex_heartbeat_path(session_id: "sess-A")
    assert_select "a[data-test=heartbeat-feed-open][href=?]", alex_heartbeat_path(session_id: "sess-B")
    # a non-truncated feed shows no truncation notice
    assert_select "[data-test=heartbeat-feed-truncated]", false
  end

  test "[component] an open span (no outcome) renders the in-progress placeholder" do
    open = event(category: "Workflow", reason_slug: "certify and open the PR",
                 outcome_slug: nil, closed_at: nil, seq: 0)

    render partial: "heartbeat/feed",
           locals: { feed_events: [open], pokemon_by_slug: {}, feed_truncated: false,
                     feed_total: 1, feed_limit: 200 }

    assert_select "[data-test=feed-in-progress]"
    assert_match(/in progress/, rendered)
  end

  test "[component] a truncated feed surfaces the truncation notice with its counts" do
    e = event(seq: 0, closed_at: Time.current, outcome_slug: "done")

    render partial: "heartbeat/feed",
           locals: { feed_events: [e], pokemon_by_slug: {}, feed_truncated: true,
                     feed_total: 250, feed_limit: 200 }

    assert_select "[data-test=heartbeat-feed-truncated]"
    assert_match "200", rendered
    assert_match "250", rendered
  end
end
