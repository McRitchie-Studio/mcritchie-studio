require "test_helper"

# [component] the per-SPAN grading drawer body (heartbeat/activity_drawer) — the span-level
# mirror of the per-action drawer. It shows the span summary (status + measured
# token/cost/model of the activity) and two grade editors (Alex + the McRitchie audit)
# that POST to E2's grade_event endpoint. No inline radios — the editors use the same
# disposition TOGGLE buttons as the per-action drawer.
class HeartbeatEventDrawerTest < ActionView::TestCase
  def event(**attrs)
    AgentActivity.create!({ session_id: "d", category: "Explore", reason_slug: "find issue with api",
                          opened_at: Time.current, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  def action(**attrs)
    AgentAction.create!({ session_id: "d", kind: "grep", outcome: "ok", actor: "agent",
                           seq: attrs.fetch(:seq, 0), occurred_at: Time.current }.merge(attrs))
  end

  test "[component] the span drawer renders Alex + McRitchie editors posting to the E2 endpoint" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "found the seam",
               model: "claude-opus-4-8", tokens_in: 9500, tokens_out: 610, cost: 0.2579)
    a1 = action(agent_activity_id: ev.id, seq: 0, model: "claude-opus-4-8", tokens_in: 9400, tokens_out: 360, cost: 0.05)

    render partial: "heartbeat/activity_drawer",
           locals: { event: ev, actions: [a1], alex: nil, mcr: nil }

    # two grade editors, both posting to the span-grade endpoint
    assert_select "form[data-test=span-grade-form]", 2
    assert_select "form[action=?]", heartbeat_activity_grade_path(ev), 2
    assert_select "form[data-grader=alex]"
    assert_select "form[data-grader=mcr]"
    # the two graders are carried as hidden fields
    assert_select "form[data-grader=alex] input[name=grader][value=alex]"
    assert_select "form[data-grader=mcr] input[name=grader][value=mcr]"
    # disposition is a toggle, never an inline radio
    assert_select "input[type=radio]", false
    # the measured span summary surfaces; action fallback usage does not backfill it
    assert_includes rendered, "9.5k/610"
    assert_includes rendered, "opus-4-8"
    assert_includes rendered, "$0.2579"
    refute_includes rendered, "9.4k/360"
  end

  test "[component] only Alex's span editor carries the bank/discard controls" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")

    render partial: "heartbeat/activity_drawer",
           locals: { event: ev, actions: [], alex: nil, mcr: nil }

    # Alex banks; the McRitchie audit does not
    assert_select "form[data-grader=alex] button[value=bank]", 1
    assert_select "form[data-grader=mcr] button[value=bank]", false
  end

  test "[component] an existing span grade pre-fills its editor slug" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    alex = ActionGrade.create!(agent_activity: ev, grader: "alex", disposition: "not",
                               slug: "span drifted off its stated reason")

    render partial: "heartbeat/activity_drawer",
           locals: { event: ev, actions: [], alex: alex, mcr: nil }

    assert_select "form[data-grader=alex] input[name=slug][value=?]", "span drifted off its stated reason"
  end
end
