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

  # task devops-sub-hour-follow-ups: bin/release posts each act's per-phase durations
  # as one `step_timings` event, exactly as release_event_ruby spells it.
  test "a step_timings event carries the act's seconds per phase and stamps no stage" do
    release = Release.open!
    before = release.reload.attributes.slice(*release.attributes.keys.grep(/_at\z/))

    event = Release::Conductor.record_event!(
      release: release, step: "step_timings", status: "completed", source: "conductor",
      message: "⏱ step durations: sweep 3m 4s · ci gate 11m 0s",
      metadata: { "act" => "prepare", "steps" => { "sweep" => 184, "ci_gate" => 660 } },
      idempotency_key: "#{release.slug}:step_timings:prepare:2026-11-11T05:00:00Z"
    )

    assert event.persisted?
    assert_equal({ "act" => "prepare", "steps" => { "sweep" => 184, "ci_gate" => 660 } }, event.reload.metadata)
    assert_nil Release::EVENT_STAGE_STAMPS[%w[step_timings completed]]
    assert_equal before.except("updated_at", "duration_metrics_cached_at"), release.reload.attributes.slice(*before.keys).except("updated_at", "duration_metrics_cached_at"),
                 "a timing report moves no stage"
  end
end
