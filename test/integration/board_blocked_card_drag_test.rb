require "test_helper"

# Regression coverage for the blocked-card drag bug (fix-forward on PR #138).
#
# Blocked tasks ride the Building dropzone (a block means more building to do) but
# the card is tagged data-stage="blocked". The old onEnd read oldStage from the
# CARD, so an in-place reorder of a blocked card computed oldStage="blocked" vs
# newStage="building" and silently PATCHed the task un-blocked; a failed PATCH then
# reverted to a non-existent dropzone-blocked and stranded the card. Blocked also
# rides the Building lane, which collapsed below ~1250px on the Deploy board —
# hiding a needs-attention task by default.
#
# The drag itself is SortableJS (mouse-driven, not native DnD) and is not exercised
# by the minitest harness, so the regression is locked at the integration tier:
# the rendered DOM is stage-consistent, the drag handler carries the same-zone
# guard that prevents the un-blocking PATCH, and the Building lane stays visible.
class BoardBlockedCardDragTest < ActionDispatch::IntegrationTest
  test "a blocked task renders inside the Building dropzone and no Blocked column exists" do
    task = Task.create!(title: "stalled needs attention", stage: "blocked")

    get tasks_path
    assert_response :success

    # The blocked card lives in the Building dropzone (data-stage="building")…
    assert_select "#dropzone-building[data-stage='building'] #card-#{task.slug}", count: 1
    # …yet the card itself is tagged data-stage="blocked" — the asymmetry the drag
    # handler must reconcile without un-blocking the task.
    assert_select "#card-#{task.slug}[data-stage='blocked']", count: 1
    # There is NO standalone Blocked column on either board, so any revert that
    # looked up dropzone-blocked would strand the card.
    assert_select "#dropzone-blocked", count: 0
  end

  test "the drag handler reads stage from the dropzones and guards same-zone reorders" do
    get tasks_path
    assert_response :success
    js = css_select("script").map(&:text).join("\n")

    # Stage is sourced from the dropzones (evt.from / evt.to), never the card's
    # data-stage — so reordering a blocked card never reads oldStage="blocked".
    assert_includes js, "const fromZone = evt.from;"
    assert_includes js, "const toZone = evt.to;"
    # A same-zone drop short-circuits BEFORE any PATCH: an in-place reorder cannot
    # change a task's stage.
    assert_includes js, "if (fromZone !== toZone) {"
    # A blocked card maps back to dropzone-building, so a revert never targets a
    # missing zone.
    assert_includes js, "stage === 'blocked' ? 'building' : stage"
    # The stranding revert (look up dropzone-<oldStage>, which is dropzone-blocked
    # for a blocked card) is gone.
    refute_includes js, "getElementById('dropzone-' + oldStage)"
  end

  test "the Building lane stays visible on the narrow Deploy board" do
    get deployments_path
    assert_response :success
    doc = Nokogiri::HTML(@response.body)

    building_col = doc.at_css("#dropzone-building").parent
    designed_col = doc.at_css("#dropzone-designed").parent

    # An upstream lane (designed) still collapses below ~1250px behind All Stages…
    assert_includes designed_col[":class"].to_s, "max-[1250px]:hidden"
    # …but Building is exempt from the collapse — a blocked task riding it must
    # never hide on a narrow screen.
    refute_includes building_col[":class"].to_s, "max-[1250px]:hidden"
  end
end
