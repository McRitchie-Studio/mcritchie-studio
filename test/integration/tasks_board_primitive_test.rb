require "test_helper"

# [integration] The /tasks board is rebased onto the studio/board ENGINE PRIMITIVE
# (studio/board/_board + Studio::Board::Rankable/Reorderable). Assert the EFFECT, not
# a proxy: a real reorder restamps the 100-gap rank AND the board re-renders in the
# new order, and the card/dropzone identity contract the primitive's SortableJS +
# live observer depend on holds.
class TasksBoardPrimitiveTest < ActionDispatch::IntegrationTest
  setup { @admin = users(:alex) }

  test "[integration] the tasks board renders through the studio/board primitive" do
    task = Task.create!(title: "primitive render probe", stage: "designed")

    get tasks_path
    assert_response :success

    # The primitive shell is present and wired to THIS app's endpoints.
    board = css_select("[data-test='studio-board']").first
    assert board, "the board renders through studio/board/_board"
    xdata = board["x-data"].to_s
    assert_includes xdata, "studioBoard(", "driven by the studioBoard factory"
    assert_includes xdata, %q("reorderUrl":"/tasks/reorder.json"), "reorder POSTs to the same route"
    assert_includes xdata, %q("moveUrl":"/tasks/:id.json"), "a cross-column move PATCHes the task"
    assert_includes xdata, %q("attr":"stage"), "the move param is task[stage]"
    assert_includes xdata, %q("idAttr":"slug"), "cards are keyed by slug"

    # The ZONE half of the identity contract (the SortableJS + live-observe target).
    assert_select "#dropzone-designed.kanban-dropzone[data-stage='designed']", count: 1
    assert_select "[data-board-count='designed']", count: 1
    # The CARD half — the card partial is unchanged, so its contract still holds.
    assert_select "#card-#{task.slug}.kanban-card[data-slug='#{task.slug}'][data-stage='designed']", count: 1
    # The card resolves the app-filter gate from the OUTER taskBoardChrome scope.
    card = css_select("#card-#{task.slug}").first
    assert_includes card["x-show"].to_s, "matchesFilter("
    assert_includes card["x-show"].to_s, "appVisible("
  end

  test "[integration] a reorder POST restamps the 100-gap rank and reorders the board" do
    log_in_as(@admin)
    a = Task.create!(title: "primitive reorder card a", stage: "designed")
    b = Task.create!(title: "primitive reorder card b", stage: "designed")
    c = Task.create!(title: "primitive reorder card c", stage: "designed")

    # DOM order top→bottom = [c, a, b]; under `position DESC` the top card holds the
    # highest 100-gapped rank (index 0 → len*100). The board POSTs the advisory zone
    # too; the shared reorder action ignores it and reads only `slugs`.
    post reorder_tasks_path(format: :json),
         params: { slugs: [c.slug, a.slug, b.slug], zone: "designed" }, as: :json
    assert_response :success

    assert_equal 300, c.reload.position, "top card (index 0) → (len - 0) * 100"
    assert_equal 200, a.reload.position, "middle card (index 1) → (len - 1) * 100"
    assert_equal 100, b.reload.position, "bottom card (index 2) → (len - 2) * 100"

    # The EFFECT is visible on reload: the board renders in the restamped order.
    get tasks_path
    order = card_order_in("dropzone-designed")
    assert_operator order.index("card-#{c.slug}"), :<, order.index("card-#{a.slug}"),
                    "the top-ranked card renders above the middle one"
    assert_operator order.index("card-#{a.slug}"), :<, order.index("card-#{b.slug}"),
                    "the middle-ranked card renders above the bottom one"
  end

  private

  # Card element ids within a dropzone, top → bottom.
  def card_order_in(dropzone_id)
    doc = Nokogiri::HTML(@response.body)
    zone = doc.at_css("##{dropzone_id}")
    assert zone, "dropzone ##{dropzone_id} should render"
    zone.css(".kanban-card").map { |el| el["id"] }
  end
end
