require "test_helper"

# [unit] AgentAction.for_activity_feed — the narrowed SELECT behind the
# /agents/activities drill-down (the ecosystem's heaviest page). The feed renders
# `input` (a preview + tooltip) but NEVER `output` (the captured tool RESULT — a
# whole file read / command stdout / transcript dump, by far the widest column),
# which only the /alex/heartbeat drawer reads. This locks in the query SHAPE: the
# scope drops `output` and keeps every other column the feed reads, so the wide
# blob stays out of the page's payload without changing what renders.
class AgentActionTest < ActiveSupport::TestCase
  def build_action(**attrs)
    activity = AgentActivity.create!(session_id: "sess-feed", category: "Explore",
                                     reason_slug: "find the api issue", opened_at: Time.current, seq: 0)
    AgentAction.create!({ session_id: "sess-feed", kind: "grep", outcome: "ok", actor: "agent",
                          seq: 0, occurred_at: Time.current, agent_activity_id: activity.id,
                          input: %({"command":"grep foo"}), output: "x" * 50_000 }.merge(attrs))
  end

  test "for_activity_feed omits the heavy output column from the SELECT" do
    assert_includes AgentAction::FEED_OMITTED_COLUMNS, "output",
                    "output is the wide unrendered blob the feed must not load"
    select_sql = AgentAction.for_activity_feed.to_sql
    assert_no_match(/["']?output["']?/, select_sql,
                    "the feed SELECT must not name the output column: #{select_sql}")
  end

  test "for_activity_feed record does not carry output but keeps the columns the feed renders" do
    build_action

    loaded = AgentAction.for_activity_feed.first
    refute loaded.has_attribute?("output"),
           "a feed-scoped record must not load the output blob"
    assert_raises(ActiveModel::MissingAttributeError) { loaded.output }

    # Every column the feed actually renders is still present.
    %w[id agent_activity_id occurred_at seq source_turn_uuid mascot kind summary
       event_slug key_method key_method_lang outcome cost tokens_in tokens_out input].each do |col|
      assert loaded.has_attribute?(col), "feed scope must keep #{col} (the feed reads it)"
    end
    assert_equal %({"command":"grep foo"}), loaded.input, "the rendered input is unchanged"
  end

  test "the default (unscoped) load still carries output for the heartbeat drawer" do
    build_action

    loaded = AgentAction.first
    assert loaded.has_attribute?("output"), "the drawer path still needs the full record"
    assert_equal "x" * 50_000, loaded.output
  end
end
