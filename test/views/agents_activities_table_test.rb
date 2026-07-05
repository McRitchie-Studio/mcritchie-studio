require "test_helper"

# [component] the /agents/activities table partial — the reimagined 7-column x 3-sub-row
# feed. Each activity is a tbody: Agent (stacked soul-over-mascot), Activity (category +
# goal / →result-with-fade / key command), Cost (cost / model / tokens), Details
# (time+status / task / action-count+spinner), and the Alex + McRitchie inline grade
# cells. Expanding drills into the raw actions (2-sub-row: #seq KIND + summary / key
# method; cost / tokens; #seq KIND + outcome + raw JSON) which carry their OWN inline
# grade cells.
class AgentsActivitiesTableTest < ActionView::TestCase
  def activity(**attrs)
    AgentActivity.create!({ session_id: "s", category: "Explore", reason_slug: "find issue with api",
                            opened_at: Time.current, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  def action(**attrs)
    AgentAction.create!({ session_id: "s", kind: "grep", outcome: "ok", actor: "agent",
                          seq: attrs.fetch(:seq, 0), occurred_at: Time.current }.merge(attrs))
  end

  def render_table(activity_rows, **locals)
    render partial: "agents/activities_table",
           locals: { activity_rows: activity_rows, pokemon_by_slug: {} }.merge(locals)
  end

  test "[component] renders the six-column header" do
    render_table []
    %w[Agent Activity Cost Details Alex McRitchie].each do |h|
      assert_select "thead th", text: h
    end
  end

  test "[component] the activity column stacks category+goal, faded result, and key command" do
    ev = activity(category: "Explore", reason_slug: "find the capture seam",
                  outcome_slug: "found the nil-guard", closed_at: Time.current,
                  key_method: "grep -rn AgentAction", key_method_lang: "bash")

    render_table [[ev, []]]

    assert_select "[data-test=aa-activity-category]", text: "Explore"
    assert_select "[data-test=aa-activity-goal]", text: "find the capture seam"
    # the result is wrapped in the overflow_fade component (the fading edge)
    assert_select "[data-test=aa-activity-result] .relative.overflow-hidden"
    assert_includes rendered, "found the nil-guard"
    assert_select "[data-test=aa-activity-keymethod] [data-test=key-method-chip][data-lang=bash]"
  end

  test "[component] an open activity renders the in-progress placeholder and a spinner" do
    ev = activity(category: "Workflow", reason_slug: "certify and open the PR",
                  outcome_slug: nil, closed_at: nil)

    render_table [[ev, []]]

    assert_select "[data-test=aa-activity-result]", text: /in progress/
    assert_select "[data-test=aa-activity-status] .aa-spinner, .aa-details .aa-spinner"
    assert_no_match(/found the nil-guard/, rendered)
  end

  test "[component] the cost column stacks cost, model, and tokens rolled up across actions" do
    ev = activity(closed_at: Time.current, outcome_slug: "done")
    a1 = action(agent_activity_id: ev.id, seq: 0, model: "claude-opus-4-8", tokens_in: 9400, tokens_out: 360, cost: 0.05)
    a2 = action(agent_activity_id: ev.id, seq: 1, model: "claude-opus-4-8", tokens_in: 6800, tokens_out: 2400, cost: 0.09)

    render_table [[ev, [a1, a2]]]

    assert_select "[data-test=aa-activity-cost]", text: "$0.1400"
    assert_select ".aa-cost-model", text: "opus-4-8"
    assert_select ".aa-cost-tok", text: "16.2k/2.8k"
  end

  test "[component] the details column stacks time+status, task, and action count" do
    ev = activity(closed_at: Time.current, outcome_slug: "done", task_slug: "agents-activities-page-redesign")
    a1 = action(agent_activity_id: ev.id, seq: 0)

    render_table [[ev, [a1]]]

    assert_select "[data-test=aa-activity-time]"
    assert_select "[data-test=event-status]", text: "done"
    assert_select "[data-test=aa-activity-task]", text: "agents-activities-page-redesign"
    assert_select "[data-test=aa-activity-count]", text: "1 action"
  end

  test "[component] each activity carries Alex + McRitchie inline grade cells posting to the activity endpoint" do
    ev = activity(closed_at: Time.current, outcome_slug: "done")

    render_table [[ev, []]]

    assert_select "td[data-test=aa-activity-grade-alex] form[action=?]", heartbeat_activity_grade_path(ev)
    assert_select "td[data-test=aa-activity-grade-mcr] form[action=?]", heartbeat_activity_grade_path(ev)
    assert_select "td[data-test=aa-activity-grade-alex] input[name=disposition][value=good]"
    assert_select "td[data-test=aa-activity-grade-alex] input[name=disposition][value=not]"
    assert_select "td[data-test=aa-activity-grade-alex] button.aa-gradeclear"
  end

  test "[component] an existing activity grade pre-checks its radio and shows its note slug" do
    ev = activity(closed_at: Time.current, outcome_slug: "done")
    grade = ActionGrade.create!(agent_activity: ev, grader: "alex", disposition: "good",
                                slug: "clean activity with a crisp outcome")

    render_table [[ev, []]], activity_grades: { ev.id => { "alex" => grade } }

    assert_select "td[data-test=aa-activity-grade-alex] input[value=good][checked]"
    assert_select "[data-test=aa-activity-note-alex]", text: /clean activity with a crisp outcome/
    assert_select "tbody[data-test=aa-activity][data-alex-graded=true]"
  end

  test "[component] an activity with no actions renders the empty drill-down row" do
    ev = activity(closed_at: Time.current, outcome_slug: "done")

    render_table [[ev, []]]

    assert_select "tr.aa-emptyrow"
  end

  test "[component] a drilled-down action row shows #seq KIND + summary, key method, cost, and raw JSON" do
    ev = activity(closed_at: Time.current, outcome_slug: "done")
    act = action(agent_activity_id: ev.id, seq: 3, kind: "bash", outcome: "ok",
                 summary: "search deployments view for wrap classes",
                 input: '{"command":"grep -rniE wrap app/views"}',
                 key_method: "grep -rniE wrap", key_method_lang: "bash",
                 cost: 0.063, tokens_in: 6700, tokens_out: 297)

    render_table [[ev, [act]]]

    row = "tr[data-test=aa-action]"
    assert_select "#{row} .aa-seqbadge", text: "#3"
    assert_select "#{row} [data-test=aa-action-summary]", text: "search deployments view for wrap classes"
    assert_select "#{row} [data-test=aa-action-keymethod] [data-test=key-method-chip][data-lang=bash]"
    assert_select "#{row} [data-test=aa-action-cost]", text: "$0.0630"
    assert_select "#{row} [data-test=aa-action-outcome]", text: "ok"
    assert_select "#{row} [data-test=aa-action-input]"
    assert_includes rendered, "grep -rniE wrap app/views"
  end

  test "[component] action rows carry their own Alex + McRitchie grade cells posting to the action endpoint" do
    ev = activity(closed_at: Time.current, outcome_slug: "done")
    act = action(agent_activity_id: ev.id, seq: 0)

    render_table [[ev, [act]]]

    assert_select "tr[data-test=aa-action] td[data-test=aa-action-grade-alex] form[action=?]", heartbeat_grade_path(act)
    assert_select "tr[data-test=aa-action] td[data-test=aa-action-grade-mcr] form[action=?]", heartbeat_grade_path(act)
  end

  test "[component] the action row carries its grade hydration data and no model cell" do
    ev = activity(closed_at: Time.current, outcome_slug: "done")
    act = action(agent_activity_id: ev.id, seq: 0, model: "claude-opus-4-8")

    render_table [[ev, [act]]]

    assert_select "tr[data-test=aa-action][data-id-field=agent_action_id][data-row-id=?]", act.id.to_s
    # cost column at action altitude drops the model sub-row (only cost + tokens)
    assert_select "tr[data-test=aa-action] .aa-cost-model", false
  end
end
