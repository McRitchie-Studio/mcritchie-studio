require "test_helper"

# The board's default task set — the scope that carries /tasks' and /deployments'
# page cost.
#
# Its own file rather than the bottom of task_test.rb: that file is one of the
# suite's APPEND hotspots (config/test_health.yml ratchets it), and this is a
# distinct concern with its own name.
#
# The boards used to load EVERY task to draw 57 cards — 1,212 tasks, 14,170
# TaskEvents and 3,742 GateRuns per production request, about 56% of everything
# the request allocated. These pin the scope that fixed it.
class TaskBoardScopeTest < ActiveSupport::TestCase
  # --- the default set ---------------------------------------------------------

  test "[unit] board_default_tasks drops archived and keeps every live stage" do
    Task.delete_all
    %w[designed building submitted reviewed assembled shipped archived].each do |stage|
      Task.create!(title: "board default #{stage} task", stage: stage)
    end

    stages = Task.board_default_tasks(Task.ordered).map(&:stage)

    assert_not_includes stages, "archived"
    assert_equal %w[assembled building designed reviewed shipped submitted], stages.sort
  end

  test "[unit] board_default_tasks caps shipped at the newest BOARD_SHIPPED_LIMIT" do
    Task.delete_all
    limit = Task::BOARD_SHIPPED_LIMIT
    shipped = (limit + 4).times.map { |i| Task.create!(title: "board shipped #{i}", stage: "shipped") }
    live = Task.create!(title: "board live one", stage: "building")

    drawn = Task.board_default_tasks(Task.ordered)

    assert_equal limit, drawn.count { |task| task.stage == "shipped" }
    assert_includes drawn.map(&:slug), live.slug, "the cap must not touch a live stage"
    # `ordered` floats the freshest to the top, so the cap keeps the NEWEST — the
    # opposite slice would show a board frozen on ancient releases.
    assert_includes drawn.map(&:slug), shipped.last.slug
    assert_not_includes drawn.map(&:slug), shipped.first.slug
  end

  test "[unit] board_capped_stage_totals reports a trimmed column, and nothing else" do
    Task.delete_all
    Task.create!(title: "capped totals live task", stage: "building")
    Task::BOARD_SHIPPED_LIMIT.times { |i| Task.create!(title: "capped totals shipped #{i}", stage: "shipped") }

    # Exactly at the limit nothing was trimmed, so there is nothing to report —
    # the badge stays a plain number.
    assert_empty Task.board_capped_stage_totals

    Task.create!(title: "capped totals one over", stage: "shipped")

    assert_equal({ "shipped" => Task::BOARD_SHIPPED_LIMIT + 1 }, Task.board_capped_stage_totals)
  end

  test "[unit] board_capped_stage_totals counts through the scope it is given" do
    Task.delete_all
    (Task::BOARD_SHIPPED_LIMIT + 5).times do |i|
      Task.create!(title: "scoped totals shipped #{i}", stage: "shipped",
                   agent_slug: i.zero? ? "carl" : "avi")
    end

    # An agent-filtered board must advertise ITS total, not the pipeline's, or the
    # badge describes cards the page did not draw.
    assert_empty Task.board_capped_stage_totals(Task.where(agent_slug: "carl"))
    assert_equal({ "shipped" => Task::BOARD_SHIPPED_LIMIT + 4 },
                 Task.board_capped_stage_totals(Task.where(agent_slug: "avi")))
  end
end
