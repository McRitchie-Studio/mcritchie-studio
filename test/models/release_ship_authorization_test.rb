require "test_helper"
require Rails.root.join("bin/lib/ship_authority").to_s

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
    ends_at = 30.minutes.from_now.change(usec: 0)
    request!(ends_at: ends_at)
    first = @rel.grant_ship_authorization!(actor: "alex@example.com", source: "web")
    again = @rel.grant_ship_authorization!(actor: "someone-else", source: "web")
    # The key bin/release records ship's own completion under (ShipAuthority.idempotency_key).
    conductor_stamp = @rel.record_event!(step: "ship_authorized", status: "completed", source: "conductor",
                                         idempotency_key: "#{@rel.slug}:ship_authorized:completed:#{ends_at.utc.iso8601}")

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

  # The conductor's timed-lapse completion, exactly as bin/release records it:
  # `ship_authorized completed` flagged lapsed, keyed by the window it closed.
  def lapse!(ends_at)
    @rel.record_event!(step: "ship_authorized", status: "completed", source: "conductor", actor: "steffon",
                       idempotency_key: "#{@rel.slug}:ship_authorized:completed:lapsed:#{ends_at.utc.iso8601}",
                       metadata: { "mode" => "timed", "lapsed" => true, "granted_via" => "window-lapse",
                                   "window_ends_at" => ends_at.utc.iso8601 })
  end

  test "[unit] regression: an earlier run's lapse is not a grant for a re-run's fresh request" do
    first_end = 5.minutes.ago.change(usec: 0)
    request!(ends_at: first_end, at: 35.minutes.ago)
    lapse!(first_end)
    refute @rel.reload.ship_authorization_granted?, "a lapse is recorded, but it is not an operator grant"
    assert_equal true, @rel.ship_authorization_state["lapsed"]

    # The re-run posts a fresh window; the old lapse must not answer it.
    second_end = 30.minutes.from_now.change(usec: 0)
    request!(ends_at: second_end)
    @rel.reload
    refute @rel.ship_authorization_granted?, "the earlier lapse must not read as a grant for the fresh request"
    state = @rel.ship_authorization_state
    assert_equal false, state["granted"]
    assert_equal false, state["lapsed"]
    assert_equal second_end, @rel.ship_authorization_window&.ends_at, "the fresh window stays open"
  end

  test "[unit] a grant counts only for the latest request, and a fresh grant lands for a re-run" do
    first_end = 5.minutes.ago.change(usec: 0)
    request!(ends_at: first_end, at: 35.minutes.ago)
    old_grant = @rel.grant_ship_authorization!(actor: "alex@example.com")
    assert @rel.reload.ship_authorization_granted?

    request!(ends_at: 30.minutes.from_now)
    refute @rel.reload.ship_authorization_granted?, "the previous run's grant does not authorize the new request"

    fresh = @rel.grant_ship_authorization!(actor: "alex@example.com")
    refute_equal old_grant.id, fresh.id, "the re-run's grant is its own row, not the old one returned by key"
    assert @rel.reload.ship_authorization_granted?
    assert_equal fresh.id, @rel.ship_authorization_grant.id
  end

  test "[unit] a grant recorded before any request authorizes nothing" do
    @rel.grant_ship_authorization!(actor: "alex@example.com")
    request!
    refute @rel.reload.ship_authorization_granted?
  end

  # Drives the real ShipAuthority timed loop against this release: the recorder
  # writes through the model under the key bin/release uses, the reader is the
  # one bin/release polls (ship_authorization_state + the lapse blockers).
  def timed_ship!(start:, minutes: 1)
    now = start
    recorder = lambda do |status, metadata|
      @rel.record_event!(step: "ship_authorized", status: status, source: "conductor", actor: "steffon", occurred_at: now,
                         idempotency_key: ShipAuthority.idempotency_key(@rel.slug, status, metadata) ||
                                          "#{@rel.slug}:ship_authorized:#{status}",
                         metadata: metadata)
    end
    reader = lambda do |blockers:|
      state = @rel.reload.ship_authorization_state
      state.slice("granted", "granted_by", "granted_via")
           .merge("blockers" => blockers && !state["granted"] ? @rel.ship_window_lapse_blockers : [])
    end
    ShipAuthority.take!(mode: "timed", release_slug: @rel.slug, minutes: minutes, recorder: recorder, reader: reader,
                        confirmer: ->(_) { true }, say: ->(_) { }, clock: -> { now },
                        sleeper: ->(seconds) { now += seconds }, interval: 60)
  end

  test "[integration] a timed re-run after a lapse re-reads the escalations instead of the old lapse" do
    g3_verdict!(true)
    assert_equal :lapsed_proceed, timed_ship!(start: 2.hours.ago), "run 1: green, no escalation, the lapse proceeds"

    member = Task.create!(title: "Escalated between ship runs", stage: "reviewed", release_slug: @rel.slug)
    member.block!(by: "avi", kind: "dependency")
    Activity.create!(task_slug: member.slug, activity_type: "qa_feedback", agent_slug: "avi",
                     description: "POLICY QUESTION", metadata: { "summary" => "Escalated: chip default", "kind" => "dependency" })

    error = assert_raises(ShipAuthority::Refused) { timed_ship!(start: 1.hour.ago) }
    assert_match(/#{member.slug} carries an open escalation/, error.message,
                 "run 2 must not read run 1's lapse as a grant and skip the fresh escalation check")
  end

  test "[integration] the web grant and a timed ship's own completion are one row" do
    started_at = Time.current
    request!(ends_at: started_at + 30.minutes)
    grant = @rel.grant_ship_authorization!(actor: "alex@example.com")
    ends_at = (started_at + 30.minutes).utc.iso8601
    assert_equal ShipAuthority.idempotency_key(@rel.slug, "completed", { "granted_via" => "web", "window_ends_at" => ends_at }),
                 grant.idempotency_key, "the model and bin/release must derive the same grant key"
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
