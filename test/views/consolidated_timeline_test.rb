require "test_helper"

# [component] the consolidated stage-timeline partial — each transition renders as
# a standard container (from→to, the completing crew, measured duration, reported
# usage), and an open intent renders a live in-progress block with a ticker.
class ConsolidatedTimelineTest < ActionView::TestCase
  setup do
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
    @carl    = Agent.create!(name: "Carl", slug: "carl")
    @agents  = Agent.all.to_a
  end

  test "renders a standard block per transition with crew, duration, and reported usage" do
    task = Task.create!(title: "component timeline task", stage: "submitted")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 3.hours.ago)
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 2.hours.ago, seconds_in_from: 3600, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 1.hour.ago, seconds_in_from: 9000, source: "cli",
                      model: "claude-opus-4-8", tokens_in: 1000, tokens_out: 2000, cost: "5.40", actor: "carl")

    render partial: "tasks/consolidated_timeline", locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_select "[data-test='stage-timeline']"
    assert_select "[data-test='timeline-block']", minimum: 3
    assert_includes rendered, "claude-opus-4-8"
    assert_includes rendered, "5.40"
    assert_includes rendered, "in Building"
  end

  test "renders a live in-progress block with a ticker for an open review intent" do
    task = Task.create!(title: "component live task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed",
                             reviewers: [{ "slug" => "carl", "weight" => "heavy" },
                                         { "slug" => "shannon", "weight" => "light" }])

    render partial: "tasks/consolidated_timeline", locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_select "[data-test='timeline-inprogress']"
    assert_select "[data-test='timeline-live']"
    assert_includes rendered, "Carl"
    assert_includes rendered, "Shannon"
    assert_includes rendered, "heavy"
  end
end
