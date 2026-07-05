require "test_helper"

# [integration] the E2 span-level grade endpoint: POST /alex/heartbeat/events/:id/grade
# upserts ONE ActionGrade for (event, grader) and returns JSON only. It mirrors the
# per-action #grade semantics (disposition/slug/long_form/intent=bank|discard) but
# targets a narrated AgentActivity SPAN and never touches a view — E2 is deliberately
# view-free so it doesn't collide with E3 (which owns all heartbeat UI). Reads are a
# public meta surface, but grade WRITES are admin-only (see HeartbeatGradeAuthTest),
# so the write scenarios below authenticate as the admin.
class HeartbeatEventGradeTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def span(**attrs)
    AgentActivity.create!({ session_id: "ev-int", category: "Explore",
                          reason_slug: "find issue with api", opened_at: Time.current,
                          seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  def grade_for(event, grader)
    ActionGrade.for_event(event).by_grader(grader).first
  end

  test "[integration] grading a span persists the disposition with a default slug" do
    e = span

    assert_difference -> { ActionGrade.count }, 1 do
      post heartbeat_activity_grade_path(e), params: { grader: "alex", disposition: "good" }
    end

    assert_response :success
    grade = grade_for(e, "alex")
    assert_equal "good", grade.disposition
    assert_equal "find issue with api", grade.slug, "slug defaults to the span's reason slug"
    assert_nil grade.agent_action_id, "a span grade carries no action FK"
    assert_equal e.id, grade.agent_activity_id
  end

  test "[integration] the JSON response carries the event FK and a null action FK" do
    e = span

    post heartbeat_activity_grade_path(e),
         params: { grader: "alex", disposition: "not", slug: "narrated the span vaguely" },
         as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "not", body["disposition"]
    assert_equal "narrated the span vaguely", body["slug"]
    assert_equal e.id, body["agent_activity_id"]
    assert_nil body["agent_action_id"]
    assert_equal "alex", body["grader"]
  end

  test "[integration] re-grading the same grader updates the one row (no duplicate)" do
    e = span
    post heartbeat_activity_grade_path(e), params: { grader: "alex", disposition: "good" }

    assert_no_difference -> { ActionGrade.count } do
      post heartbeat_activity_grade_path(e),
           params: { grader: "alex", disposition: "not", slug: "span was noisy and unfocused" }
    end

    grade = grade_for(e, "alex")
    assert_equal "not", grade.disposition
    assert_equal "span was noisy and unfocused", grade.slug
  end

  test "[integration] banking a span grade lands it in the Insight Bank; discarding excludes it" do
    e = span

    post heartbeat_activity_grade_path(e),
         params: { grader: "alex", disposition: "good", slug: "promote this to a guardrail", intent: "bank" }
    grade = grade_for(e, "alex")
    assert grade.banked
    assert_includes ActionGrade.banked, grade

    post heartbeat_activity_grade_path(e),
         params: { grader: "alex", disposition: "good", slug: "promote this to a guardrail", intent: "discard" }
    grade.reload
    assert_not grade.banked
    assert grade.discarded
    assert_not_includes ActionGrade.banked, grade
  end

  test "[integration] clearing a span grade removes the existing grader row" do
    e = span
    ActionGrade.create!(agent_activity: e, grader: "alex", disposition: "good",
                        slug: "clean span with a crisp outcome")

    assert_difference -> { ActionGrade.count }, -1 do
      post heartbeat_activity_grade_path(e),
           params: { grader: "alex", intent: "clear" },
           as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["cleared"]
    assert_equal "alex", body["grader"]
    assert_equal e.id, body["agent_activity_id"]
    assert_nil grade_for(e, "alex")
  end

  test "[integration] clearing a missing span grade is a no-op" do
    e = span

    assert_no_difference -> { ActionGrade.count } do
      post heartbeat_activity_grade_path(e),
           params: { grader: "mcr", intent: "clear" },
           as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["cleared"]
    assert_equal "mcr", body["grader"]
  end

  test "[integration] the McRitchie audit is a second grade row on the same span" do
    e = span

    post heartbeat_activity_grade_path(e),
         params: { grader: "alex", disposition: "not", slug: "narrated the span vaguely" }
    post heartbeat_activity_grade_path(e),
         params: { grader: "mcr", disposition: "good", slug: "agree, tighten the reason slug" }

    assert_equal 2, e.action_grades.count
    assert grade_for(e, "mcr").mcr?, "the McRitchie row audits Alex's span grade"
  end

  test "[integration] an invalid grade returns a 422 JSON error and writes no row" do
    e = span

    assert_no_difference -> { ActionGrade.count } do
      post heartbeat_activity_grade_path(e), params: { grader: "steffon", disposition: "good" }, as: :json
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body["error"].present?, "the JSON error body names the failure"
  end
end
