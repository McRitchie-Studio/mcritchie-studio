require "test_helper"

# [unit] Release's production-authority window (design section 6): derived from
# the ship_authorized request/grant events alone, the one idempotent grant
# write, and the two lapse blockers a timed ship reads before proceeding.
class ReleaseShipAuthorizationTest < ActiveSupport::TestCase
  setup do
    @rel = Release.open!
  end

  # One closed G3 attempt with the given verdict, through the model's own funnel.
  def g3_verdict!(success)
    GateRun.open!(subject_type: "release", subject_slug: @rel.slug, key: "g3_candidate", actor: "avi", source: "conductor")
    GateRun.close!(subject_type: "release", subject_slug: @rel.slug, key: "g3_candidate", success: success, actor: "avi", source: "conductor")
  end

  def request!(ends_at: 30.minutes.from_now, mode: "timed", at: Time.current)
    @rel.record_event!(step: "ship_authorized", status: "started", source: "conductor", actor: "steffon",
                       occurred_at: at,
                       metadata: { "mode" => mode, "window_ends_at" => ends_at.utc.iso8601, "window_minutes" => 30 })
  end

  test "[unit] no window before a request, and none for an ask/auto request that carries no end" do
    assert_nil @rel.ship_authorization_window
    @rel.record_event!(step: "ship_authorized", status: "started", source: "conductor", metadata: { "mode" => "auto" })
    assert_nil @rel.reload.ship_authorization_window
    assert_equal false, @rel.ship_authorization_state["granted"]
    assert_equal "auto", @rel.ship_authorization_state["mode"]
  end

  test "[unit] a timed request opens the production window at the end it carries" do
    ends_at = 30.minutes.from_now.change(usec: 0)
    request!(ends_at: ends_at)

    window = @rel.reload.ship_authorization_window
    assert_equal "production", window.kind
    assert_equal ends_at, window.ends_at
    assert_equal 30, window.minutes
    refute window.lapsed?(Time.current)
    assert_equal ends_at.utc.iso8601, @rel.ship_authorization_state["window_ends_at"]
  end

  test "[unit] the grant closes the window and is idempotent under the conductor's key" do
    request!
    first = @rel.grant_ship_authorization!(actor: "alex@example.com", source: "web")
    again = @rel.grant_ship_authorization!(actor: "someone-else", source: "web")
    conductor_stamp = @rel.record_event!(step: "ship_authorized", status: "completed", source: "conductor",
                                         idempotency_key: "#{@rel.slug}:ship_authorized:completed")

    assert_equal first.id, again.id, "a second click returns the same row"
    assert_equal first.id, conductor_stamp.id, "ship's own completion stamp after a grant is the same row"
    assert_equal 1, @rel.release_events.for_step("ship_authorized").completed.count
    assert @rel.reload.ship_authorization_granted?
    assert_nil @rel.ship_authorization_window
    state = @rel.ship_authorization_state
    assert_equal true, state["granted"]
    assert_equal "alex@example.com", state["granted_by"]
    assert_equal "web", state["granted_via"]
    assert @rel.stage_reached?("confirmed"), "the grant stamps the tracker's confirmed stage like ship's own completion does"
  end

  test "[unit] lapse blockers name a missing or red G3 and an open escalation on a member" do
    blockers = @rel.ship_window_lapse_blockers
    assert_equal 1, blockers.size
    assert_match(/G3 Candidate is unrecorded/, blockers.first)

    g3_verdict!(false)
    assert_match(/G3 Candidate is red/, @rel.reload.ship_window_lapse_blockers.first)

    g3_verdict!(true)
    assert_empty @rel.reload.ship_window_lapse_blockers, "a green G3 and no escalation means the lapse default applies"

    member = Task.create!(title: "Escalated release member task", stage: "reviewed", release_slug: @rel.slug)
    member.block!(by: "avi", kind: "dependency")
    Activity.create!(task_slug: member.slug, activity_type: "qa_feedback", agent_slug: "avi",
                     description: "POLICY QUESTION", metadata: { "summary" => "Escalated: chip default", "kind" => "dependency" })
    blockers = @rel.reload.ship_window_lapse_blockers
    assert_equal 1, blockers.size
    assert_match(/#{member.slug} carries an open escalation/, blockers.first)

    member.unblock!
    assert_empty @rel.reload.ship_window_lapse_blockers, "a cleared escalation no longer holds the ship"
  end

  test "[unit] a rework block on a member is not an escalation and holds nothing" do
    g3_verdict!(true)
    member = Task.create!(title: "Reworked release member task", stage: "reviewed", release_slug: @rel.slug)
    member.block!(by: "carl", kind: "rework")
    Activity.create!(task_slug: member.slug, activity_type: "qa_feedback", agent_slug: "carl",
                     description: "fix", metadata: { "summary" => "Spacing off", "kind" => "rework" })

    assert_empty @rel.reload.ship_window_lapse_blockers
  end
end
