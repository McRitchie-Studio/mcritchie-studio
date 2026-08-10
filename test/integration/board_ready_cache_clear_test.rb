require "test_helper"

# [component] data-alpine-ready is a RUNTIME attribute: each board sets it after
# its $nextTick directive walk, so it means "this board is wired and interactive"
# — something server markup can never truthfully claim, and something a Turbo
# cache snapshot must never carry. Without a turbo:before-cache cleanup the flag
# rides into the snapshot and a restoration visit paints a preview where it reads
# true BEFORE Alpine re-initialises — any selector gating on the flag passes
# against unwired chrome. Both hub boards (/tasks chrome and /deployments) must
# ship the cleanup listener and must not server-render the flag.
#
# This tier guards the rendered contract (listener present, flag absent from
# markup); the runtime EFFECT — dispatching turbo:before-cache actually strips
# the flag — is proven in the [e2e] halves of tasks_board_filter_test and
# board_app_filter_test.
class BoardReadyCacheClearTest < ActionDispatch::IntegrationTest
  # The cleanup's distinctive fragments. Asserting the selector+delete pair (not
  # a bare addEventListener, which the modal host also ships) keeps this
  # non-vacuous: only the board cleanup targets the board root's ready flag.
  CLEAR_SELECTOR = %q{document.querySelectorAll("[data-test='kanban-board'][data-alpine-ready]")}
  CLEAR_DELETE   = "delete el.dataset.alpineReady"

  test "[component] the tasks board registers the before-cache ready-flag cleanup" do
    get tasks_path
    assert_response :success
    assert_board_ready_cache_contract
  end

  test "[component] the deploy board registers the before-cache ready-flag cleanup" do
    get deployments_path
    assert_response :success
    assert_board_ready_cache_contract
  end

  private

  def assert_board_ready_cache_contract
    # Inline script content — assert on the raw body (Nokogiri reads elements,
    # not script text).
    assert_includes @response.body, "turbo:before-cache",
      "the board page registers a turbo:before-cache handler"
    assert_includes @response.body, CLEAR_SELECTOR,
      "the before-cache cleanup targets the board root's runtime ready flag"
    assert_includes @response.body, CLEAR_DELETE,
      "the before-cache cleanup deletes the ready flag, not merely reads it"

    # The flag stays runtime-only: the server must never render it, or the gate
    # it exists for ("Alpine finished wiring") is vacuously open on first paint.
    board = css_select("[data-test='kanban-board']").first
    assert board, "the board root renders"
    assert_nil board["data-alpine-ready"],
      "data-alpine-ready must not be server-rendered — it is set by Alpine at runtime"
  end
end
