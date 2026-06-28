require "test_helper"

class ReleaseEventTest < ActiveSupport::TestCase
  test "records a release checkpoint with idempotency" do
    release = Release.open!

    first = ReleaseEvent.record!(
      release: release,
      step: "ship_gate",
      status: "completed",
      source: "conductor",
      idempotency_key: "ship-gate-once"
    )
    second = ReleaseEvent.record!(
      release: release,
      step: "ship_gate",
      status: "completed",
      source: "conductor",
      idempotency_key: "ship-gate-once"
    )

    assert_equal first, second
    assert_equal 1, release.release_events.where(idempotency_key: "ship-gate-once").count
  end

  test "agent completion events require model tokens and cost" do
    release = Release.open!
    event = release.release_events.build(step: "ship_gate", status: "completed", source: "api")

    assert_not event.valid?
    assert_includes event.errors[:model], "is required for api completed events"
    assert_includes event.errors[:tokens_in], "is required for api completed events"
    assert_includes event.errors[:tokens_out], "is required for api completed events"
    assert_includes event.errors[:cost], "is required for api completed events"
  end

  test "started events do not require usage yet" do
    event = Release.open!.release_events.build(step: "deploy_prod", status: "started", source: "api")

    assert event.valid?
  end

  test "conductor completion events may be deterministic only" do
    event = Release.open!.release_events.build(step: "deploy_prod", status: "completed", source: "conductor")

    assert event.valid?
  end
end
