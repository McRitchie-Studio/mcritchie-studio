require "test_helper"
require "minitest/mock"

# DeploymentsBroadcaster: turns a TaskEvent into a re-rendered board card pushed
# over DeploymentsChannel so /deployments updates live.
class DeploymentsBroadcasterTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
  end

  # A task that actually walked designed→building→submitted with an actor, so its
  # crew entries aren't empty and the deploy card renders its crew (and, with an
  # open intent, the live ticker).
  def built_submitted_task
    task = Task.create!(title: "Broadcaster sample task", stage: "designed")
    Current.task_event_actor = "carl"
    task.update!(stage: "building")
    task.update!(stage: "submitted")
    task
  ensure
    Current.reset
  end

  # --- [unit] payload shape ---------------------------------------------------

  test "a transition event yields a stage_change card payload" do
    task = built_submitted_task
    payload = DeploymentsBroadcaster.new(task.task_events.transitions.last).payload

    assert_equal "stage_change", payload["type"]
    assert_equal task.slug, payload["slug"]
    assert_equal "submitted", payload["stage"]
    assert_equal "building", payload["from_stage"]
    assert_includes payload["html"], %(id="card-#{task.slug}"), "the payload carries the rendered card"
  end

  test "an intent event yields an intent payload whose card shows the live ticker" do
    task = built_submitted_task
    intent = task.record_intent_event(to_stage: "reviewed",
                                      reviewers: [{ "slug" => "carl", "weight" => "heavy" },
                                                  { "slug" => "shannon", "weight" => "light" }])
    payload = DeploymentsBroadcaster.new(intent).payload

    assert_equal "intent", payload["type"]
    assert_equal "submitted", payload["stage"]
    assert_includes payload["html"], "crew-live", "the re-rendered card shows the in-progress ticker"
  end

  # --- [integration] the broadcast actually reaches the stream ----------------

  test "task_event publishes exactly one message on the deployments stream" do
    event = built_submitted_task.task_events.transitions.last
    assert_broadcasts(DeploymentsChannel::STREAM, 1) do
      DeploymentsBroadcaster.task_event(event)
    end
  end

  test "the TaskEvent after-commit hook broadcasts via the broadcaster" do
    event = built_submitted_task.task_events.transitions.last
    assert_broadcasts(DeploymentsChannel::STREAM, 1) do
      event.send(:broadcast_to_deployments_board)
    end
  end

  test "a backfilled event never broadcasts (bulk history must not spam the board)" do
    task = built_submitted_task
    backfilled = task.task_events.create!(from_stage: "submitted", to_stage: "reviewed",
                                          occurred_at: Time.current, metadata: { "backfilled" => true })
    assert_no_broadcasts(DeploymentsChannel::STREAM) do
      backfilled.send(:broadcast_to_deployments_board)
    end
  end

  test "a render failure is swallowed so it never breaks the move" do
    event = built_submitted_task.task_events.transitions.last
    DeploymentsBroadcaster.stub(:new, ->(_e) { raise "boom" }) do
      assert_nothing_raised do
        assert_nil DeploymentsBroadcaster.task_event(event)
      end
    end
  end

  # Regression for the SEV-1: a misconfigured cable adapter raises Gem::LoadError on
  # the first broadcast — a ScriptError, NOT a StandardError — which a plain
  # `rescue StandardError` let escape the after_commit → 500 on every task write.
  # The best-effort guard MUST also catch the ScriptError hierarchy.
  test "a non-StandardError from the broadcast (e.g. a missing cable adapter gem) never breaks the move" do
    refute Gem::LoadError.ancestors.include?(StandardError), "guard premise: Gem::LoadError is not a StandardError"
    event = built_submitted_task.task_events.transitions.last
    DeploymentsBroadcaster.stub(:new, ->(_e) { raise Gem::LoadError, "redis is not part of the bundle" }) do
      assert_nothing_raised do
        assert_nil DeploymentsBroadcaster.task_event(event)
      end
    end
  end
end
