require "test_helper"

# [integration] the T5 feedback layer over the read-only heartbeat: the inline radios
# render, #grade upserts a grade (alex|mcr) with a default slug, bank!/discard! route
# through it, the McRitchie audit is a second row, and banked grades surface on the
# Insight Bank page. Reads are a public meta surface; grade WRITES are admin-only
# (see HeartbeatGradeAuthTest), so this suite authenticates as the admin.
class HeartbeatFeedbackTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def capture(**attrs)
    AgentAction.create!({ session_id: "fb-int", kind: "edit", outcome: "ok", actor: "agent",
                           seq: attrs.fetch(:seq, 0), occurred_at: Time.current,
                           event_slug: "Implement the view code" }.merge(attrs))
  end

  def grade_for(action, grader)
    ActionGrade.for_action(action).by_grader(grader).first
  end

  test "[integration] the read-only event heartbeat links each action to its drawer + the Insight Bank" do
    a = capture(stage: "building") # no agent_activity_id -> renders in the Unlabeled group

    get alex_heartbeat_path

    assert_response :success
    # the event heartbeat is read-only: no inline grading radios on the table
    assert_select "input[type=radio]", false
    # but a drilled-down action still links to its per-action grading drawer
    assert_select "tr[data-test=heartbeat-event-action]", 1
    assert_match heartbeat_feedback_path(a), response.body
    assert_select "aside[data-test=heartbeat-drawer]"
    assert_select "a[href=?]", alex_insights_path, text: /Insight Bank/
  end

  test "[integration] grading an action persists the disposition with a default slug" do
    a = capture(stage: "building")

    assert_difference -> { ActionGrade.count }, 1 do
      post heartbeat_grade_path(a), params: { grader: "alex", disposition: "good", surface: "inline" }
    end

    grade = grade_for(a, "alex")
    assert_equal "good", grade.disposition
    assert_equal "Implement the view code", grade.slug, "slug defaults to the action's event slug"
  end

  test "[integration] re-grading the same grader updates the one row (no duplicate)" do
    a = capture(stage: "building")
    post heartbeat_grade_path(a), params: { grader: "alex", disposition: "good", surface: "inline" }

    assert_no_difference -> { ActionGrade.count } do
      post heartbeat_grade_path(a),
           params: { grader: "alex", disposition: "not", slug: "slow to spot the bug", surface: "drawer" }
    end

    grade = grade_for(a, "alex")
    assert_equal "not", grade.disposition
    assert_equal "slow to spot the bug", grade.slug
  end

  test "[integration] banking a grade lands it in the Insight Bank; discarding excludes it" do
    a = capture(stage: "building")

    post heartbeat_grade_path(a),
         params: { grader: "alex", disposition: "good", slug: "promote this to a guardrail",
                   intent: "bank", surface: "drawer" }
    grade = grade_for(a, "alex")
    assert grade.banked
    assert_includes ActionGrade.banked, grade

    post heartbeat_grade_path(a),
         params: { grader: "alex", disposition: "good", slug: "promote this to a guardrail",
                   intent: "discard", surface: "drawer" }
    grade.reload
    assert_not grade.banked
    assert grade.discarded
    assert_not_includes ActionGrade.banked, grade
  end

  test "[integration] the McRitchie audit is a second grade row on the same action" do
    a = capture(stage: "building")

    post heartbeat_grade_path(a),
         params: { grader: "alex", disposition: "not", slug: "slow diagnosing the column", surface: "drawer" }
    post heartbeat_grade_path(a),
         params: { grader: "mcr", disposition: "good", slug: "agree check siblings first", surface: "drawer" }

    assert_equal 2, a.action_grades.count
    assert grade_for(a, "mcr").mcr?, "the McRitchie row audits Alex's grade"
  end

  test "[integration] a banked grade appears on the Insight Bank page" do
    a = capture(stage: "building")
    post heartbeat_grade_path(a),
         params: { grader: "alex", disposition: "good", slug: "promote this to a guardrail",
                   intent: "bank", surface: "drawer" }

    get alex_insights_path

    assert_response :success
    assert_select "[data-test=insight-bank]"
    assert_select "[data-test=insight] .hb-fbslug", false # sanity: insight cards use their own markup
    assert_match "promote this to a guardrail", response.body
  end

  test "[integration] the Insight Bank shows a friendly empty state with nothing banked" do
    get alex_insights_path

    assert_response :success
    assert_select "[data-test=insight-bank-empty]"
  end

  test "[integration] #grade responds with a turbo_stream that replaces the inline cell" do
    a = capture(stage: "building")

    post heartbeat_grade_path(a),
         params: { grader: "alex", disposition: "good", surface: "inline" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match "fb-alex-#{a.id}", response.body
    assert_match "hb-stat-insights", response.body
  end

  test "[integration] the feedback drawer body loads both editors for an action" do
    a = capture(stage: "building")

    get heartbeat_feedback_path(a)

    assert_response :success
    assert_select "turbo-frame#hb-drawer"
    assert_select "input[type=hidden][name=grader][value=alex]"
    assert_select "input[type=hidden][name=grader][value=mcr]"
    assert_select "button[value=bank]" # Alex editor only
  end

  test "[integration] the action drawer surfaces the FULL tool-call input and output" do
    long_input = "grep -rn AgentAction app/models #{"x" * 400}"
    long_output = "Found 12 matches across 3 files #{"y" * 400}"
    a = capture(stage: "building", input: long_input, output: long_output)

    get heartbeat_feedback_path(a)

    assert_response :success
    assert_select "[data-test=drawer-full-command]"
    # the full (untruncated) input AND output are present, not the one-line preview
    assert_select "[data-test=drawer-input]", text: long_input
    assert_select "[data-test=drawer-output]", text: long_output
  end

  test "[integration] #grade also answers JSON for the fetch fallback" do
    a = capture(stage: "building")

    post heartbeat_grade_path(a),
         params: { grader: "alex", disposition: "not", slug: "slow to spot the bug" },
         as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "not", body["disposition"]
    assert_equal "slow to spot the bug", body["slug"]
  end
end
