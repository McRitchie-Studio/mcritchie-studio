require "test_helper"

# [integration] GET /alex/heartbeat — the repointed Alex avenue renders the atomic
# trajectory table from AtomicAction.for_session(...).chronological, oldest to
# newest, grouped by stage. Read-only meta surface, so it needs no auth.
class AlexHeartbeatTest < ActionDispatch::IntegrationTest
  def capture_action(seq:, stage:, at:, session: "sess-A", **attrs)
    AtomicAction.create!({ session_id: session, kind: "edit", outcome: "ok", actor: "agent",
                           seq: seq, stage: stage, occurred_at: at }.merge(attrs))
  end

  test "alex_heartbeat_path routes to the trajectory view, repointed off the launcher placeholder" do
    assert_equal "/alex/heartbeat", alex_heartbeat_path
    assert_routing "/alex/heartbeat", controller: "heartbeat", action: "show"
  end

  test "renders the trajectory table for the latest session without auth" do
    capture_action(seq: 0, stage: nil, at: 3.minutes.ago, actor: "harness",
                   event_slug: "Boot the runtime", result_slug: "Identity resolved")
    capture_action(seq: 1, stage: "building", at: 2.minutes.ago, task_slug: "demo",
                   event_slug: "Edit the view", result_slug: "View written",
                   model: "claude-opus-4-8", tokens_in: 1000, tokens_out: 200, cost: "0.01")

    get alex_heartbeat_path

    assert_response :success
    assert_select "[data-test=heartbeat]"
    assert_select "tr[data-test=heartbeat-row]", 2
    assert_select "tbody[data-test=heartbeat-group][data-stage=session]"
    assert_select "tbody[data-test=heartbeat-group][data-stage=building]"
    assert_match "Boot the runtime", response.body
  end

  test "reads chronological order, presenting actions oldest to newest" do
    # Insert out of order; the view must present them oldest first.
    capture_action(seq: 2, stage: "building", at: 1.minute.ago,  event_slug: "third action")
    capture_action(seq: 0, stage: nil,        at: 3.minutes.ago, event_slug: "first action")
    capture_action(seq: 1, stage: nil,        at: 2.minutes.ago, event_slug: "second action")

    get alex_heartbeat_path

    assert_response :success
    body = response.body
    assert_operator body.index("first action"),  :<, body.index("second action")
    assert_operator body.index("second action"), :<, body.index("third action")
  end

  test "scopes to a session via the session_id param" do
    capture_action(seq: 0, stage: nil, at: 5.minutes.ago, session: "sess-A", event_slug: "session A only")
    capture_action(seq: 0, stage: nil, at: 1.minute.ago,  session: "sess-B", event_slug: "session B only")

    get alex_heartbeat_path(session_id: "sess-A")

    assert_response :success
    assert_match "session A only", response.body
    assert_no_match(/session B only/, response.body)
  end

  test "renders a friendly empty state when nothing has been captured" do
    get alex_heartbeat_path

    assert_response :success
    assert_select "[data-test=heartbeat-empty]"
  end

  # The multi-session switcher labels each option with its session's Pokémon mascot
  # ("Bulbasaur · e2f6eb27") — the mascot leads, the eight-char id keeps it unique.
  test "session switcher options lead with each session's Pokémon mascot and short id" do
    a = "e2f6eb27-415c-4f3d-81c4-5bdf64064904"
    b = "3618cc6d-6176-43d6-8cc0-45b6fcfffaa"
    Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", types: %w[grass], generation: 1)
    Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", types: %w[fire], generation: 1)
    SessionMascot.create!(session_id: a, mascot_slug: "bulbasaur")
    SessionMascot.create!(session_id: b, mascot_slug: "charizard")
    capture_action(seq: 0, stage: nil, at: 2.minutes.ago, session: a, event_slug: "A")
    capture_action(seq: 0, stage: nil, at: 1.minute.ago,  session: b, event_slug: "B")

    get alex_heartbeat_path

    assert_response :success
    assert_select "select.hb-sel option[value=?]", a, text: "Bulbasaur · e2f6eb27"
    assert_select "select.hb-sel option[value=?]", b, text: "Charizard · 3618cc6d"
  end

  # A session with no mascot row (pre-mascot or seed data) still lists — it just
  # falls back to the bare session id rather than dropping out of the switcher.
  test "session switcher falls back to the bare id when a session has no mascot" do
    a = "e2f6eb27-415c-4f3d-81c4-5bdf64064904"
    b = "3618cc6d-6176-43d6-8cc0-45b6fcfffaa"
    Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", types: %w[grass], generation: 1)
    SessionMascot.create!(session_id: a, mascot_slug: "bulbasaur")
    capture_action(seq: 0, stage: nil, at: 2.minutes.ago, session: a, event_slug: "A")
    capture_action(seq: 0, stage: nil, at: 1.minute.ago,  session: b, event_slug: "B")

    get alex_heartbeat_path

    assert_response :success
    assert_select "select.hb-sel option[value=?]", a, text: "Bulbasaur · e2f6eb27"
    assert_select "select.hb-sel option[value=?]", b, text: b
  end
end
