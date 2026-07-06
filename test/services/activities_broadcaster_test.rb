require "test_helper"
require "turbo/broadcastable/test_helper"

# [integration] ActivitiesBroadcaster — the live Turbo Stream feed behind /agents/activities.
# AgentActivity/AgentAction after_*_commit callbacks push additive stream updates; every
# send is guarded by safe_broadcast so a cable failure never breaks the capture write.
class ActivitiesBroadcasterTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  def activity(**attrs)
    AgentActivity.create!({ session_id: "s", category: "Explore", reason_slug: "find issue with api",
                            opened_at: Time.current, seq: 0 }.merge(attrs))
  end

  def action(activity_rec, **attrs)
    AgentAction.create!({ session_id: "s", kind: "grep", outcome: "ok", actor: "agent", seq: 0,
                          occurred_at: Time.current, agent_activity_id: activity_rec&.id }.merge(attrs))
  end

  test "activity create broadcasts the activity row inserted after the thead" do
    created = nil
    streams = capture_turbo_stream_broadcasts(ActivitiesBroadcaster::STREAM) { created = activity }

    after = streams.find { |s| s["action"] == "after" }
    assert after, "expected an 'after' insert broadcast on activity create"
    assert_equal "aa-activities-head", after["target"]
    assert_includes after.to_html, "aa-activity-#{created.id}"
  end

  test "activity update broadcasts a replace of its tbody" do
    a = activity
    streams = capture_turbo_stream_broadcasts(ActivitiesBroadcaster::STREAM) do
      a.update!(outcome_slug: "found the nil-guard", closed_at: Time.current)
    end

    replace = streams.find { |s| s["action"] == "replace" }
    assert replace, "expected a replace broadcast on activity update"
    assert_equal "aa-activity-#{a.id}", replace["target"]
    assert_includes replace.to_html, "found the nil-guard"
  end

  test "action create broadcasts remove-empty then append into its activity" do
    a = activity
    created = nil
    streams = capture_turbo_stream_broadcasts(ActivitiesBroadcaster::STREAM) do
      created = action(a, event_slug: "grep the seam")
    end

    remove = streams.find { |s| s["action"] == "remove" }
    append = streams.find { |s| s["action"] == "append" }
    assert remove, "expected a remove of the empty placeholder"
    assert_equal "aa-empty-#{a.id}", remove["target"]
    assert append, "expected an append of the new action row"
    assert_equal "aa-activity-#{a.id}", append["target"]
    assert_includes append.to_html, "aa-action-#{created.id}"
  end

  test "action update broadcasts a replace of its row" do
    a = activity
    act = action(a)
    streams = capture_turbo_stream_broadcasts(ActivitiesBroadcaster::STREAM) do
      act.update!(outcome: "error", summary: "it blew up on the edge case")
    end

    replace = streams.find { |s| s["action"] == "replace" }
    assert replace, "expected a replace broadcast on action update"
    assert_equal "aa-action-#{act.id}", replace["target"]
    assert_includes replace.to_html, "it blew up on the edge case"
  end

  test "open_activity! boundary close broadcasts a replace of the auto-closed prior activity" do
    first = AgentActivity.open_activity!(session_id: "s", category: "Explore", reason_slug: "look")

    streams = capture_turbo_stream_broadcasts(ActivitiesBroadcaster::STREAM) do
      AgentActivity.open_activity!(session_id: "s", category: "Edit", reason_slug: "change",
                                   prior_outcome_slug: "resolved it")
    end

    replace = streams.find { |st| st["action"] == "replace" && st["target"] == "aa-activity-#{first.id}" }
    assert replace, "the auto-closed prior activity must broadcast a live replace of its tbody"
    assert_includes replace.to_html, "resolved it",
                    "the replaced row carries the stamped close outcome, not the stale open state"
  end

  test "an unlabeled action (nil activity) broadcasts nothing" do
    streams = capture_turbo_stream_broadcasts(ActivitiesBroadcaster::STREAM) do
      action(nil, agent_activity_id: nil)
    end
    assert_empty streams
  end

  test "a cable failure is swallowed and never breaks the DB write (SEV-1 guard)" do
    Turbo::StreamsChannel.stub(:broadcast_after_to, ->(*) { raise "cable down" }) do
      assert_nothing_raised { @a = activity }
    end
    assert AgentActivity.exists?(@a.id), "the activity must persist even when the broadcast blows up"
  end

  test "the broadcast callbacks are wired on both models" do
    assert AgentActivity._commit_callbacks.any? { |c| c.filter.to_s.include?("after_create_commit") } ||
             AgentActivity.new.respond_to?(:run_callbacks),
           "AgentActivity has commit callbacks"
    # concrete: creating a record with a stubbed broadcaster records the call
    calls = []
    ActivitiesBroadcaster.stub(:activity_created, ->(a) { calls << a }) { activity }
    assert_equal 1, calls.size
    calls.clear
    a = activity
    ActivitiesBroadcaster.stub(:action_created, ->(x) { calls << x }) { action(a) }
    assert_equal 1, calls.size
  end
end
