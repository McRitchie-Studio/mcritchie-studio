require "application_system_test_case"

class HeartbeatSpansInteractionTest < ApplicationSystemTestCase
  test "[e2e] all spans separates expand and sidebar click zones" do
    span = AtomicEvent.create!(
      session_id: "system-span-zones",
      category: "Explore",
      reason_slug: "inspect heartbeat row zones",
      opened_at: Time.current,
      closed_at: Time.current,
      outcome_slug: "ready for split clicks",
      seq: 0
    )
    AtomicAction.create!(
      session_id: "system-span-zones",
      atomic_event: span,
      kind: "bash",
      outcome: "ok",
      actor: "agent",
      seq: 0,
      occurred_at: Time.current,
      event_slug: "raw action appears after expand",
      summary: "verify row zone behavior"
    )
    ActionGrade.create!(
      atomic_event: span,
      grader: ActionGrade::ALEX,
      disposition: ActionGrade::GOOD,
      slug: "clear row zone signal"
    )

    visit heartbeat_all_spans_path

    within "tbody[data-event-id='#{span.id}']" do
      assert_no_selector "tr[data-test='heartbeat-event-action']", visible: true

      find("td.hb-narr").click
      assert_selector "tr[data-test='heartbeat-event-action']", visible: true
      assert_text "raw action appears after expand"

      find("[data-test='event-grade-alex']").click
    end

    assert_selector "[data-test='heartbeat-drawer'].hb-drawer-open"
    within "turbo-frame#hb-drawer" do
      assert_text "inspect heartbeat row zones"
      assert_selector "form[data-grader='alex']"
    end
  end
end
