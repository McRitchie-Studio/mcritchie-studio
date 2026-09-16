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

  # --- an explicit ?stage= view ------------------------------------------------
  #
  # HOTFIX 2026-09-16 (archived-board-crashes-prod). `?stage=archived` used to load
  # the WHOLE column with every task's events and gate runs. A crawler requested it
  # twice on production: one request ran 23,994ms / 3,834 queries, and two of them
  # took a 512MB dyno to 1,220MB and an R15 SIGKILL, twice in 38 seconds.

  test "[unit] board_stage_tasks caps an explicit stage at the newest BOARD_STAGE_LIMIT" do
    Task.delete_all
    limit = Task::BOARD_STAGE_LIMIT
    archived = (limit + 3).times.map { |i| Task.create!(title: "stage cap archived #{i}", stage: "archived") }
    live = Task.create!(title: "stage cap live one", stage: "building")

    drawn = Task.board_stage_tasks(Task.ordered, "archived")

    assert_equal limit, drawn.size
    assert(drawn.all? { |task| task.stage == "archived" }, "an explicit stage returns only that stage")
    assert_not_includes drawn.map(&:slug), live.slug
    # `ordered` floats the freshest to the top, so the cap keeps the NEWEST.
    assert_includes drawn.map(&:slug), archived.last.slug
    assert_not_includes drawn.map(&:slug), archived.first.slug
  end

  test "[unit] board_stage_capped_totals reports a trimmed explicit stage, and nothing else" do
    Task.delete_all
    Task::BOARD_STAGE_LIMIT.times { |i| Task.create!(title: "stage totals archived #{i}", stage: "archived") }

    # Exactly at the limit nothing was trimmed, so there is nothing to report.
    assert_empty Task.board_stage_capped_totals(Task.all, "archived")

    Task.create!(title: "stage totals one over", stage: "archived")

    assert_equal({ "archived" => Task::BOARD_STAGE_LIMIT + 1 },
                 Task.board_stage_capped_totals(Task.all, "archived"))
  end

  # --- paging the explicit-stage view ------------------------------------------
  #
  # The hotfix capped ?stage= at one page and left 1,926 of 2,026 archived tasks
  # unreachable from the board. Paging brings them back WITHOUT a wider read: every
  # page is BOARD_STAGE_LIMIT rows, capped in SQL, and there is no page-size input
  # anywhere for a caller (or a crawler) to raise.

  test "[unit] board_stage_tasks pages through the older slice, never more than a page" do
    Task.delete_all
    limit = Task::BOARD_STAGE_LIMIT
    archived = (limit + 3).times.map { |i| Task.create!(title: "stage page archived #{i}", stage: "archived") }

    first = Task.board_stage_tasks(Task.ordered, "archived", page: 1)
    second = Task.board_stage_tasks(Task.ordered, "archived", page: 2)

    assert_equal limit, first.size
    assert_equal 3, second.size
    # Newest first, then the next-older slice — together every task, exactly once.
    assert_includes first.map(&:slug), archived.last.slug
    assert_includes second.map(&:slug), archived.first.slug
    assert_empty first.map(&:slug) & second.map(&:slug), "a task drawn on two pages means paging skips another"
    assert_equal archived.map(&:slug).sort, (first + second).map(&:slug).sort
  end

  test "[unit] board_stage_page clamps any requested page into the pages that exist" do
    limit = Task::BOARD_STAGE_LIMIT
    total = (limit * 2) + 1 # three pages

    assert_equal 3, Task.board_stage_page_count(total)
    assert_equal 1, Task.board_stage_page_count(0), "an empty stage still draws one (empty) page"
    assert_equal 1, Task.board_stage_page_count(limit)

    assert_equal 1, Task.board_stage_page(nil, total)
    assert_equal 1, Task.board_stage_page("", total)
    assert_equal 1, Task.board_stage_page("0", total)
    assert_equal 1, Task.board_stage_page("-4", total)
    assert_equal 1, Task.board_stage_page("abc", total)
    assert_equal 1, Task.board_stage_page(["2"], total), "an array param must not raise"
    assert_equal 2, Task.board_stage_page("2", total)
    # Past the end lands on the last page. An unclamped 10**30 would hand SQL an
    # OFFSET past bigint and 500 the page.
    assert_equal 3, Task.board_stage_page("4", total)
    assert_equal 3, Task.board_stage_page("9" * 30, total)
  end
end
