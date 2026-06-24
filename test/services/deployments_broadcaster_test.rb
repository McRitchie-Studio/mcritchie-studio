require "test_helper"
require "minitest/mock"

# DeploymentsBroadcaster: turns a TaskEvent into a Turbo Stream that patches the
# /deployments board live — a replace (intent / same column), a remove+prepend
# (cross-column move), a prepend (new task), or a remove (left the board).
# capture_turbo_stream_broadcasts returns parsed <turbo-stream> Nokogiri nodes.
class DeploymentsBroadcasterTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
  end

  REVIEWERS = [{ "slug" => "carl", "weight" => "heavy" }, { "slug" => "shannon", "weight" => "light" }].freeze

  # A task that actually walked designed→building→submitted with an actor, so its
  # crew entries aren't empty and the deploy card renders its crew + intent ticker.
  def built_submitted_task
    task = Task.create!(title: "Broadcaster sample task", stage: "designed")
    Current.task_event_actor = "carl"
    task.update!(stage: "building")
    task.update!(stage: "submitted")
    task
  ensure
    Current.reset
  end

  # --- [unit] the right Turbo action per event --------------------------------

  test "an intent REPLACES the card in place, with the live ticker" do
    task = built_submitted_task
    intent = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(intent) }

    assert_equal 1, streams.size
    assert_equal "replace", streams.first["action"]
    assert_equal "card-#{task.slug}", streams.first["target"]
    assert_includes streams.first.to_html, "crew-live", "the re-rendered card shows the in-progress ticker"
  end

  test "a cross-column stage move REMOVES the old card and PREPENDS a fresh one" do
    task = built_submitted_task
    Current.task_event_reviewers = REVIEWERS
    task.update!(stage: "reviewed")
    Current.reset
    event = task.task_events.transitions.last # submitted → reviewed

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(event) }

    assert_equal 2, streams.size
    assert(streams.any? { |s| s["action"] == "remove" && s["target"] == "card-#{task.slug}" }, "removes the old card")
    assert(streams.any? { |s| s["action"] == "prepend" && s["target"] == "dropzone-reviewed" }, "prepends to the new column")
  end

  test "a brand-new task (genesis) PREPENDS to the Designed column" do
    task = Task.create!(title: "Fresh genesis board task", stage: "designed")
    genesis = task.task_events.transitions.first # nil → designed

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(genesis) }

    assert_equal 1, streams.size
    assert_equal "prepend", streams.first["action"]
    assert_equal "dropzone-designed", streams.first["target"]
  end

  test "a task leaving the board (→ archived) REMOVES its card" do
    task = built_submitted_task
    task.update!(stage: "archived")
    event = task.task_events.transitions.last

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(event) }

    assert_equal 1, streams.size
    assert_equal "remove", streams.first["action"]
    assert_equal "card-#{task.slug}", streams.first["target"]
  end

  test "a building→blocked re-tint REPLACES in place (blocked rides the Building column)" do
    task = Task.create!(title: "Blocked column re-tint task", stage: "designed")
    Current.task_event_actor = "carl"
    task.update!(stage: "building")
    Current.reset
    task.update!(stage: "blocked")
    event = task.task_events.transitions.last # building → blocked

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(event) }

    assert_equal 1, streams.size
    assert_equal "replace", streams.first["action"]
    assert_equal "card-#{task.slug}", streams.first["target"]
  end

  # --- [unit] the hook + the SEV-1 guard --------------------------------------

  test "the after-commit hook skips backfilled (bulk history) events" do
    task = built_submitted_task
    backfilled = task.task_events.create!(from_stage: "submitted", to_stage: "reviewed",
                                          occurred_at: Time.current, metadata: { "backfilled" => true })
    streams = capture_turbo_stream_broadcasts("deployments") { backfilled.send(:broadcast_to_deployments_board) }
    assert_empty streams
  end

  test "a ScriptError from the broadcast never escapes the task write (SEV-1 guard via safe_broadcast)" do
    task = built_submitted_task
    intent = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*_a, **_k) { raise Gem::LoadError, "redis not in bundle" }) do
      assert_nothing_raised do
        assert_nil DeploymentsBroadcaster.task_event(intent)
      end
    end
  end
end
