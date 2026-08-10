require "test_helper"

# [unit] AgentAction.for_activity_feed + .for_activity_drilldown — the narrowed,
# capped load behind the /agents/activities drill-down (the ecosystem's heaviest
# page). The feed renders summary + key_method but NEITHER wide blob: `output`
# (the captured tool RESULT) never rendered, and `input` (the raw tool-call
# payload) once rode along as a full-text title tooltip — on 2026-08-09 that plus
# an uncapped drill-down (one activity: 1339 actions) put the page at 1.8-5.4 MB.
# These tests lock in the query SHAPE: the scope drops both blobs, the drilldown
# caps each activity at its FEED_ACTIONS_PER_ACTIVITY newest rows, and the
# /alex/heartbeat drawer's full-record path stays intact.
class AgentActionTest < ActiveSupport::TestCase
  def build_activity(session: "sess-feed", seq: 0)
    AgentActivity.create!(session_id: session, category: "Explore",
                          reason_slug: "find the api issue", opened_at: Time.current, seq: seq)
  end

  def build_action(activity: nil, **attrs)
    activity ||= build_activity
    AgentAction.create!({ session_id: "sess-feed", kind: "grep", outcome: "ok", actor: "agent",
                          seq: 0, occurred_at: Time.current, agent_activity_id: activity.id,
                          input: %({"command":"grep foo"}), output: "x" * 50_000 }.merge(attrs))
  end

  # Bulk-seed `count` actions under an activity with strictly increasing
  # occurred_at/seq, one INSERT (no callbacks/broadcasts) so the 1339-action
  # outage shape stays cheap to reproduce.
  def seed_actions(activity, count, base: Time.current - count)
    now = Time.current
    AgentAction.insert_all(
      count.times.map do |i|
        { session_id: activity.session_id, agent_activity_id: activity.id,
          kind: "bash", outcome: "ok", actor: "agent", seq: i,
          input: %({"command":"step #{i}"}), output: "out #{i}",
          occurred_at: base + i, created_at: now, updated_at: now }
      end
    )
  end

  test "for_activity_feed omits both heavy blobs from the SELECT" do
    assert_equal %w[input output], AgentAction::FEED_OMITTED_COLUMNS,
                 "input and output are the wide blobs the feed must not load"
    select_sql = AgentAction.for_activity_feed.to_sql
    assert_no_match(/["']?output["']?/, select_sql,
                    "the feed SELECT must not name the output column: #{select_sql}")
    assert_no_match(/["']input["']/, select_sql,
                    "the feed SELECT must not name the input column: #{select_sql}")
  end

  test "for_activity_feed record carries neither blob but keeps the columns the feed renders" do
    build_action

    loaded = AgentAction.for_activity_feed.first
    %w[input output].each do |blob|
      refute loaded.has_attribute?(blob),
             "a feed-scoped record must not load the #{blob} blob"
    end
    assert_raises(ActiveModel::MissingAttributeError) { loaded.output }
    assert_raises(ActiveModel::MissingAttributeError) { loaded.input }

    # Every column the feed actually renders is still present.
    %w[id agent_activity_id occurred_at seq source_turn_uuid mascot kind summary
       event_slug key_method key_method_lang outcome cost tokens_in tokens_out].each do |col|
      assert loaded.has_attribute?(col), "feed scope must keep #{col} (the feed reads it)"
    end
  end

  test "the default (unscoped) load still carries both blobs for the heartbeat drawer" do
    build_action

    loaded = AgentAction.first
    assert loaded.has_attribute?("output"), "the drawer path still needs the full record"
    assert_equal "x" * 50_000, loaded.output
    assert_equal %({"command":"grep foo"}), loaded.input
  end

  test "for_activity_drilldown caps a 1339-action activity at its newest rows, feed-scoped" do
    activity = build_activity
    seed_actions(activity, 1339)

    rows = AgentAction.for_activity_drilldown([activity.id]).to_a

    assert_equal AgentAction::FEED_ACTIONS_PER_ACTIVITY, rows.size,
                 "the outage shape (1339 actions) must load only the cap"
    # The cap keeps the NEWEST rows, in the feed's newest-first display order.
    expected_seqs = (1339 - AgentAction::FEED_ACTIONS_PER_ACTIVITY...1339).to_a.reverse
    assert_equal expected_seqs, rows.map(&:seq)
    # And the rows ride the narrowed feed columns — no blob sneaks back in.
    refute rows.first.has_attribute?("input")
    refute rows.first.has_attribute?("output")
  end

  test "for_activity_drilldown caps PER activity, leaving an under-cap neighbour whole" do
    big   = build_activity(seq: 0)
    small = build_activity(seq: 1)
    seed_actions(big, AgentAction::FEED_ACTIONS_PER_ACTIVITY + 7)
    seed_actions(small, 3)

    rows = AgentAction.for_activity_drilldown([big.id, small.id]).to_a
                      .group_by(&:agent_activity_id)

    assert_equal AgentAction::FEED_ACTIONS_PER_ACTIVITY, rows[big.id].size,
                 "the over-cap activity is bounded"
    assert_equal 3, rows[small.id].size, "the under-cap activity keeps every row"
  end
end
