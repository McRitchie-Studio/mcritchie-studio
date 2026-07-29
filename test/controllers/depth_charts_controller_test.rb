require "test_helper"

# [integration/component] The depth chart rebased onto the studio/board ENGINE
# PRIMITIVE (studio-engine 0.29.0). Asserts the rendered board contract (DG3 grid +
# the card/dropzone identity), the reorder restamp (DG2 sequential 1..N depths via
# Studio::Board::Reorderable), the DG4 lock skip, and toggle_lock. Records are built
# inline (no depth-chart fixtures) — the same shape the news/content board tests use.
class DepthChartsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @team  = Team.create!(name: "Test Gridiron", sport: "football", league: "nfl", emoji: "🏈")
    @chart = DepthChart.create!(team_slug: @team.slug, slug: "#{@team.slug}-depth")
    @p1 = Person.create!(first_name: "Aaron", last_name: "Starter")
    @p2 = Person.create!(first_name: "Bobby", last_name: "Backup")
    @p3 = Person.create!(first_name: "Carl",  last_name: "Third")
    @e1 = DepthChartEntry.create!(depth_chart_slug: @chart.slug, person_slug: @p1.slug, position: "QB", side: "offense", depth: 1)
    @e2 = DepthChartEntry.create!(depth_chart_slug: @chart.slug, person_slug: @p2.slug, position: "QB", side: "offense", depth: 2)
    @e3 = DepthChartEntry.create!(depth_chart_slug: @chart.slug, person_slug: @p3.slug, position: "QB", side: "offense", depth: 3)
  end

  test "show renders the depth chart on the studio board primitive (grid + card/zone contract)" do
    get team_depth_chart_path(@team.slug)
    assert_response :success

    # The primitive board root + the DG3 two-level side→position grid.
    assert_select "section[data-test='studio-board']"
    assert_select "[data-board-group='offense']", 1, "Offense renders as a labelled board group"
    # The ZONE half — the QB lane is a dropzone keyed by position (zone_attr: position).
    assert_select "#dropzone-QB.kanban-dropzone[data-position=?]", "QB"
    # The CARD half — id=card-<id>, .kanban-card, data-id, data-position.
    card = css_select("#card-#{@e1.id}.kanban-card").first
    assert card, "the entry renders via the board primitive card-shell"
    assert_equal @e1.id.to_s, card["data-id"]
    assert_equal "QB", card["data-position"]

    # The CDN SortableJS <script> is GONE (CSP win — the vendored engine sortable
    # loads once in the layout).
    assert_select "script[src*='cdn.jsdelivr.net/npm/sortablejs']", false
  end

  test "show marks a locked starter with .kanban-locked so the factory pins it" do
    @e1.update!(locked: true)
    get team_depth_chart_path(@team.slug)
    assert_response :success
    assert_select "#card-#{@e1.id}.kanban-locked", 1, "a locked entry carries .kanban-locked (undraggable)"
    assert_select "#card-#{@e2.id}.kanban-locked", 0, "an unlocked entry does not"
  end

  test "reorder restamps a lane's entry_ids to sequential depths 1..N (DG2)" do
    log_in_as(@admin)
    post reorder_depth_chart_path(@team.slug),
         params: { entry_ids: [@e3.id, @e1.id, @e2.id] }, as: :json
    assert_response :success

    assert_equal 1, @e3.reload.depth, "the DOM-top entry becomes depth 1"
    assert_equal 2, @e1.reload.depth
    assert_equal 3, @e2.reload.depth
  end

  test "reorder skips a locked entry — the pinned starter keeps its depth (DG4)" do
    log_in_as(@admin)
    @e1.update!(locked: true, depth: 1)

    # A drag that tries to sink the locked starter to the bottom of the lane.
    post reorder_depth_chart_path(@team.slug),
         params: { entry_ids: [@e2.id, @e3.id, @e1.id] }, as: :json
    assert_response :success

    assert_equal 1, @e1.reload.depth, "the locked starter keeps its depth (untouched)"
    assert_equal 1, @e2.reload.depth, "the unlocked cards restamp 1..N by DOM order"
    assert_equal 2, @e3.reload.depth
  end

  test "toggle_lock flips the entry lock flag and renders it" do
    log_in_as(@admin)
    assert_not @e1.locked

    post toggle_lock_depth_chart_entry_path(@e1.id), as: :json
    assert_response :success
    assert JSON.parse(response.body)["locked"], "the response reports the new locked state"
    assert @e1.reload.locked

    post toggle_lock_depth_chart_entry_path(@e1.id), as: :json
    assert_not @e1.reload.locked, "a second toggle clears it"
  end
end
