require "test_helper"

# [component] the /intelligence dashboard template renders its chart containers,
# the summary tiles, and the leaderboard tables from a TaskIntelligence object —
# the unit the controller assigns. Renders the template standalone with @intel.
class IntelligenceDashboardTest < ActionView::TestCase
  setup do
    TaskEvent.delete_all
    Task.delete_all

    task = Task.create!(title: "Render fixture task", slug: "intel-view-1", stage: "shipped",
                        po_size: "small", dev_size: "medium", actual_size: "large")
    task.task_events.delete_all
    task.update_columns(created_at: 6.hours.ago, completed_at: Time.current)
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: Time.current, seconds_in_from: 5_400,
                      tokens_in: 500, tokens_out: 700, cost: 3.10,
                      model: "claude-opus-4-8", source: "cli", kind: TaskEvent::TRANSITION)

    # ActionView::TestCase transfers the test's instance variables into the view.
    @intel = TaskIntelligence.new
  end

  test "renders the dashboard shell, every chart container, and the panels" do
    render template: "intelligence/index"

    assert_select "[data-test='intelligence-dashboard']"
    assert_select "h1", text: "Task Intelligence"
    assert_select "[data-test='summary-tiles'] .card", minimum: 8

    %w[chart-stage-speed chart-cycle-time chart-cycle-trend chart-tokens-task
       chart-tokens-stage chart-tokens-trend chart-cost-task chart-cost-trend
       chart-estimate-accuracy chart-model-mix].each do |id|
      assert_select "##{id}"
    end

    # leaderboard tables populated from the fixture task
    assert_select "[data-test='priciest-tasks'] table tbody tr", minimum: 1
    assert_select "[data-test='priciest-tasks']", text: /Render fixture task/
    assert_select "[data-test='estimate-misses'] table tbody tr", minimum: 1
  end
end
