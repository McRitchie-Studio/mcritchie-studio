require "test_helper"

# [integration] the security + robustness contract for the learning-loop grade
# surface (audit 2026-07-02, high findings #3 + #5):
#
#   * READS stay a public "open meta surface" — the heartbeat, the span list, the
#     Insight Bank, and the drawers render with no auth.
#   * WRITES are ADMIN-ONLY. The grade / bank / discard endpoints are the write
#     path into the OPSD Insight Bank AND the McRitchie audit-of-Alex ground truth,
#     so an anonymous client must not be able to forge a grade (least of all a
#     `grader: "mcr"` audit row) or poison the bank. Mirrors TasksController.
#   * The Insight Bank must render a banked SPAN grade — the Alex heartbeat's
#     normal output — instead of 500ing on a nil atomic_action.
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

  # ── writes are admin-only ──────────────────────────────────────────────────

  test "[integration] an anonymous action-grade POST is rejected and writes no row" do
    a = action

    assert_no_difference -> { ActionGrade.count } do
      post heartbeat_grade_path(a), params: { grader: "mcr", disposition: "good" }
    end

    assert_not response.successful?, "an unauthenticated grade write must not succeed"
  end

  test "[integration] an anonymous span-grade POST is rejected and writes no row" do
    e = span

    assert_no_difference -> { ActionGrade.count } do
      post heartbeat_event_grade_path(e), params: { grader: "mcr", disposition: "good" }, as: :json
    end

    assert_not response.successful?, "an unauthenticated span-grade write must not succeed"
  end

  test "[integration] a logged-in admin can grade — the write path still works" do
    a = action
    log_in_as(users(:alex))

    assert_difference -> { ActionGrade.count }, 1 do
      post heartbeat_grade_path(a), params: { grader: "alex", disposition: "good" }, as: :json
    end

    assert_response :success
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
