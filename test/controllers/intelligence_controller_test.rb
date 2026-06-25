require "test_helper"

# [integration] IntelligenceController#index assembles the TaskIntelligence data
# and renders the dashboard (public-read, like the other board surfaces).
class IntelligenceControllerTest < ActionDispatch::IntegrationTest
  test "renders the dashboard with chart containers and panels" do
    TaskEvent.delete_all
    Task.delete_all

    task = Task.create!(title: "Priced shipped task", slug: "intel-ctrl-1", stage: "shipped",
                        po_size: "medium", dev_size: "large", actual_size: "large")
    task.task_events.delete_all
    task.update_columns(created_at: 8.hours.ago, completed_at: Time.current)
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: Time.current, seconds_in_from: 7_200,
                      tokens_in: 1_000, tokens_out: 2_000, cost: 4.25,
                      model: "claude-opus-4-8", source: "cli", kind: TaskEvent::TRANSITION)

    get intelligence_path

    assert_response :success
    assert_select "[data-test='intelligence-dashboard']"
    assert_select "h1", text: "Task Intelligence"
    # every chart container is present (Chartkick renders into these divs)
    %w[chart-stage-speed chart-cycle-time chart-cycle-trend chart-tokens-task
       chart-tokens-stage chart-tokens-trend chart-cost-task chart-cost-trend
       chart-estimate-accuracy chart-model-mix].each do |id|
      assert_select "##{id}"
    end
    # the per-chart Chartkick init scripts are emitted
    assert_select "script", { text: /new Chartkick/, minimum: 1 }
    # the priciest-tasks leaderboard surfaces the seeded task + its spend
    assert_select "[data-test='priciest-tasks']", text: /Priced shipped task/
  end

  test "renders with no data (empty states, still 200)" do
    TaskEvent.delete_all
    Task.delete_all

    get intelligence_path

    assert_response :success
    assert_select "[data-test='summary-tiles']"
    assert_select "[data-test='priciest-tasks']", text: /No spend recorded yet/
  end
end
