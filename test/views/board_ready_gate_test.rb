require "test_helper"

# [component] The /tasks board's readiness gate. `taskBoardChrome` stamps
# data-alpine-ready on itself only once the INNER studio/board primitive is live,
# because the cards — and their x-show filter bindings — live in that inner
# component, which initialises AFTER this chrome. Everything that waits on the
# flag (the board-filter e2e, any future one) is really waiting for the cards to
# be interactive, so the flag must not outrun them.
#
# This pins the STRUCTURAL invariant the gate stands on: the chrome reaches the
# primitive with `this.$el.querySelector('[data-test="studio-board"]')`, so the
# inner section must render INSIDE the chrome element. Move it out — a sibling, a
# teleport, its own frame — and boardData() silently returns null forever: the
# flag would then only ever appear via the bail-out, and the race it exists to
# close comes straight back, invisibly.
class BoardReadyGateTest < ActionView::TestCase
  setup do
    @tasks_by_stage = { "building" => [] }
    # The board partial reads session/authorisation context the controller supplies
    # in production. Stubbed to the LEAST-privileged reader, so the structure this
    # pins is the one every visitor gets.
    def view.pokemon_by_slug = {}
    def view.admin? = false
    def view.logged_in? = false
    def view.current_user = nil
  end

  def render_board
    # The partial renders siblings by bare name ("board_top_links"), which resolve
    # against the lookup prefixes — supplied by the controller in production, so a
    # view test has to state them.
    view.lookup_context.prefixes = %w[tasks application]
    render partial: "tasks/board",
           locals: { tasks_by_stage: @tasks_by_stage, agents: [], crew_board: false }
  end

  test "[component] the inner board renders INSIDE the chrome that gates on it" do
    render_board

    chrome = css_select("[data-test='kanban-board']").first
    assert chrome, "the chrome element must render"
    assert_equal "taskBoardChrome()", chrome["x-data"],
                 "the gate lives on this component — boardData() resolves from its $el"

    inner = css_select("[data-test='kanban-board'] [data-test='studio-board']")
    assert_equal 1, inner.size,
                 "the primitive must be a DESCENDANT of the chrome, or " \
                 "this.$el.querySelector('[data-test=\"studio-board\"]') returns null " \
                 "and the ready flag stops meaning the cards are interactive"
  end

  test "[component] the chrome does not stamp the ready flag server-side" do
    render_board

    chrome = css_select("[data-test='kanban-board']").first
    assert_nil chrome["data-alpine-ready"],
               "the flag is earned at runtime once the inner board is live — " \
               "a server-rendered one would be true before any JS ran"
  end
end
