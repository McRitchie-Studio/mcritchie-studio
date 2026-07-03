require "test_helper"

# [integration] the learning-loop grade surface contract.
#
# BUILD-FIRST (2026-07-03): grade/bank/discard WRITES are PUBLIC — Mr. McRitchie can
# grade and confirm (incl. `grader: "mcr"`) without an admin login while the pipeline
# is being built. This deliberately re-opens audit finding #5 (writes public, mcr
# forgeable) as a conscious tradeoff; re-gate before real multi-user exposure. Reads
# were already public. The Insight Bank must still render a banked SPAN grade (the
# #337 crash fix) instead of 500ing on a nil atomic_action.
class HeartbeatGradeAuthTest < ActionDispatch::IntegrationTest
  def action(**attrs)
    AtomicAction.create!({ session_id: "auth-int", kind: "edit", outcome: "ok", actor: "agent",
                           seq: attrs.fetch(:seq, 0), occurred_at: Time.current,
                           event_slug: "Implement the view code" }.merge(attrs))
  end

  def span(**attrs)
    AtomicEvent.create!({ session_id: "auth-int", category: "Explore",
                          reason_slug: "find issue with api", opened_at: Time.current,
                          seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  # ── writes are PUBLIC (build-first) ─────────────────────────────────────────

  test "[integration] an anonymous action-grade POST succeeds and writes the row" do
    a = action

    assert_difference -> { ActionGrade.count }, 1 do
      post heartbeat_grade_path(a), params: { grader: "alex", disposition: "good" }, as: :json
    end

    assert_response :success, "grade writes are public while build-first mode holds"
  end

  test "[integration] an anonymous McRitchie confirmation (grader mcr) succeeds" do
    e = span

    assert_difference -> { ActionGrade.count }, 1 do
      post heartbeat_event_grade_path(e), params: { grader: "mcr", disposition: "good" }, as: :json
    end

    assert_response :success
    assert ActionGrade.for_event(e).by_grader("mcr").exists?, "the mcr confirmation is writable without login"
  end

  # ── reads stay public ──────────────────────────────────────────────────────

  test "[integration] the heartbeat and Insight Bank reads remain public (no auth)" do
    get alex_heartbeat_path
    assert_response :success

    get alex_insights_path
    assert_response :success
  end

  # ── the Insight Bank renders a banked SPAN grade (the crash fix) ────────────

  test "[integration] a banked SPAN grade renders on the Insight Bank without crashing" do
    e = span(reason_slug: "trace the nil-guard", task_slug: nil)
    grade = ActionGrade.create!(atomic_event: e, grader: "alex", disposition: "good",
                                slug: "promote this span to a guardrail")
    grade.bank!

    get alex_insights_path

    assert_response :success
    assert_select "[data-test=insight-bank]"
    assert_match "promote this span to a guardrail", response.body
  end

  test "[integration] a banked span grade carrying a task slug renders its provenance" do
    e = span(reason_slug: "sharp narrated outcome", task_slug: "some-task-slug", seq: 3)
    grade = ActionGrade.create!(atomic_event: e, grader: "mcr", disposition: "not",
                                slug: "the span was noisy")
    grade.bank!

    get alex_insights_path

    assert_response :success
    assert_match "the span was noisy", response.body
  end
end
