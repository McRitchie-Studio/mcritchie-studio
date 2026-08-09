require "test_helper"

# [component] The /tasks board's readiness signals and the filter row that waits
# on them. The board is TWO Alpine components — the chrome (filter chips,
# archive/delete) wrapping the engine's studio/board primitive (the cards) — and
# each stamps data-alpine-ready on its own $el after its directive walk.
#
# What this pins is what makes waiting on either flag MEAN anything: neither may
# appear in the server-rendered markup. A hardcoded data-alpine-ready satisfies
# every waiting selector before a line of JS runs, so any gate built on it is
# vacuous.
#
# SCOPE, stated plainly: it renders an EMPTY board, so it pins the two container
# sections and nothing else. The filter chips the e2e actually clicks need a real
# card (and the controller's activity ivars) to render, so they are asserted in
# TasksBoardPrimitiveTest against a real GET instead of scaffolded here.
class BoardReadyGateTest < ActionView::TestCase
  setup do
    @tasks_by_stage = { "building" => [] }
    # Authorisation context the controller supplies in production, stubbed to the
    # LEAST-privileged reader.
    def view.admin? = false
    def view.logged_in? = false
  end

  def render_board
    # The partial renders siblings by bare name ("board_top_links"), which resolve
    # against the lookup prefixes — supplied by the controller in production, so a
    # view test has to state them.
    view.lookup_context.prefixes = %w[tasks application]
    render partial: "tasks/board",
           locals: { tasks_by_stage: @tasks_by_stage, agents: [], crew_board: false }
  end

  test "[component] neither board component ships a server-rendered ready flag" do
    render_board

    %w[kanban-board studio-board].each do |component|
      element = css_select("[data-test='#{component}']").first
      assert element, "#{component} must render"
      assert_nil element["data-alpine-ready"],
                 "#{component}'s ready flag is EARNED at runtime after its directive walk; " \
                 "a server-rendered one is true before any JS runs, so every selector " \
                 "waiting on it passes instantly and the gate is vacuous"
    end
  end

  # The chrome reaches the primitive with
  # `this.$el.querySelector('[data-test="studio-board"]')` (boardData → the shared
  # toast host, count refresh, and card exit animation). Move the primitive out —
  # a sibling, a teleport, its own frame — and that lookup silently returns null.
  test "[component] the primitive renders INSIDE the chrome that reaches into it" do
    render_board

    assert_equal 1, css_select("[data-test='kanban-board'] [data-test='studio-board']").size,
                 "the primitive must stay a descendant of the chrome, or boardData() " \
                 "returns null and the chrome's delegation silently no-ops"
  end
end
