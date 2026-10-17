require "test_helper"

# [component] tasks/_deploy_board: HOW MANY LANES the six-lane board shows is asked of
# the BOARD's width (a container query on the lane row), not the window's, and the
# lane headers stand down from pinning through a semantic group variant rather than a
# stylesheet rule keyed on test hooks (board-lanes-by-board-width).
#
# Geometry — that the six lanes fit at every width, and that the headers pin — is
# settled in a browser by e2e/deployments_lane_pin. This tier pins the markup those
# results come from.
class DeployBoardLanesTest < ActionView::TestCase
  setup do
    @tasks_by_stage = {}
    controller.controller_path = "tasks" # the partial renders its siblings by relative name
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:admin?) { true }
    view.define_singleton_method(:current_user) { nil }
    render partial: "tasks/deploy_board",
           locals: { stages: Task::DEPLOYMENTS_BOARD_STAGES, title: "Deployments", live_updates: false }
  end

  def lanes = css_select("[data-test='kanban-lanes']").first
  def lane_columns = css_select("[data-test='kanban-lanes'] > div").to_a

  test "[component] the lane row is a named container and the group the headers read" do
    classes = lanes["class"].split
    assert_includes classes, "@container/lanes", "the lane count must be asked of the board"
    assert_includes classes, "group/lanes", "the headers' stand-down variant keys on this group"
    assert_equal "laneScroll", lanes[":data-lane-scroll"], "the row publishes its scroller state"
  end

  test "[component] the upstream lanes collapse by the board's width, never the window's" do
    columns = lane_columns
    assert_equal Task::DEPLOYMENTS_BOARD_STAGES.size, columns.size

    collapsible = columns.first(columns.size - 3)
    collapsible.each do |col|
      assert_equal "showAllCols ? '' : '@max-[83rem]/lanes:hidden'", col[":class"],
                   "a collapsible lane hides while the board is narrower than six lanes"
    end
    columns.last(3).each { |col| assert_nil col[":class"], "the downstream three always show" }

    # 83rem is six 13rem lanes and five 1rem gaps: the threshold IS the lanes' floor.
    columns.each { |col| assert_includes col["class"].split, "sm:min-w-[13rem]" }
    assert_includes lanes["class"].split, "gap-4"
    assert_not_includes rendered, "max-[1399px]", "no window breakpoint decides the lane count"
  end

  test "[component] the probe hands the container query's answer to the All Stages toggle" do
    probe = css_select("[data-test='kanban-lanes'] > span[data-lane-probe]").first
    assert probe, "the lane row carries the probe"
    assert_equal %w[absolute hidden @max-[83rem]/lanes:block], probe["class"].split,
                 "same threshold as the collapse, out of the flex flow"
    assert_equal "laneProbe", probe["x-ref"]

    toggle = css_select("[data-test='all-stages-toggle']").first
    assert_equal "boardNarrow", toggle["x-show"], "x-show owns the toggle's display"
    assert_equal "display: none", toggle["style"]
    assert_equal "toggleAllStages()", toggle["@click"]
    assert_not_includes toggle["class"], "max-[1399px]"
  end

  test "[component] every lane header pins, and stands down by a semantic variant" do
    headers = css_select("[data-test='stage-header']")
    assert_equal Task::DEPLOYMENTS_BOARD_STAGES.size, headers.size
    headers.each do |h|
      classes = h["class"].split
      assert_includes classes, "sticky"
      assert_includes classes, "group-data-[lane-scroll=true]/lanes:static",
                      "inside the sideways scroller the header sits in the flow"
      assert_nil h[":style"], "an Alpine style bind would wipe the composed top"
    end

    css = Rails.root.join("app/assets/tailwind/application.css").read
    assert_no_match(/data-test=["']?(kanban-lanes|stage-header)/, css,
                    "stylesheet rules key on semantic hooks, never test ids")
  end

  test "[component] lane overflow is measured on resize and on the toggle, never on scroll" do
    board = css_select("[data-test='kanban-board']").first
    assert_nil board["@scroll.window"], "vertical scroll cannot change whether the lanes overflow"
    assert_match(/toggleAllStages\(\) \{\s*this\.showAllCols = !this\.showAllCols;\s*this\.\$nextTick\(\(\) => this\.measureLanes\(\)\);/,
                 rendered)
    assert_includes rendered, "new ResizeObserver(() => this.measureLanes())"
  end
end
