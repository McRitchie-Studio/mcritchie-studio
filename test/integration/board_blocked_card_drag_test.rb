require "test_helper"

# Regression coverage for the blocked-card drag behavior.
#
# A block is a `building` ATTRIBUTE now (blocked_at set), not a stage — so a
# blocked card IS a building card (data-stage="building") wearing a red glow, and
# it rides the Building dropzone. There is no Blocked column and no card/dropzone
# stage asymmetry to reconcile. The same-zone drag guard (an in-place reorder must
# never PATCH the stage) still matters, and the Building lane still collapses below
# 1400px on the Deploy board so a stalled task is reachable via "All Stages".
class BoardBlockedCardDragTest < ActionDispatch::IntegrationTest
  test "a blocked task renders as a building card in the Building dropzone, no Blocked column" do
    task = Task.create!(title: "stalled needs attention", stage: "building")
    task.block!(by: "avi", kind: "rework")

    get tasks_path
    assert_response :success

    # The blocked card lives in the Building dropzone and IS a building card —
    # its red block glow rides the data-stage-glow attribute, not the stage.
    assert_select "#dropzone-building[data-stage='building'] #card-#{task.slug}", count: 1
    assert_select "#card-#{task.slug}[data-stage='building'][data-stage-glow='blocked']", count: 1
    # There is NO standalone Blocked column on either board.
    assert_select "#dropzone-blocked", count: 0
  end

  test "the drag handler reads stage from the dropzones and guards same-zone reorders" do
    get tasks_path
    assert_response :success
    js = css_select("script").map(&:text).join("\n")

    # Stage is sourced from the dropzones (evt.from / evt.to), never the card's
    # data-stage.
    assert_includes js, "const fromZone = evt.from;"
    assert_includes js, "const toZone = evt.to;"
    # A same-zone drop short-circuits BEFORE any PATCH: an in-place reorder cannot
    # change a task's stage.
    assert_includes js, "if (fromZone !== toZone) {"
    # The stranding revert (look up dropzone-<oldStage>) is gone.
    refute_includes js, "getElementById('dropzone-' + oldStage)"
  end

  test "the Build board subscribes live so blocked transitions patch into Building" do
    get tasks_path
    assert_response :success

    assert_select "turbo-cable-stream-source", count: 1
    assert_includes response.body, "kanbanBoard(true)"
  end

  test "the Building lane collapses on the narrow Deploy board behind All Stages" do
    get deployments_path
    assert_response :success
    doc = Nokogiri::HTML(@response.body)

    building_col = doc.at_css("#dropzone-building").parent
    designed_col = doc.at_css("#dropzone-designed").parent
    reviewed_col = doc.at_css("#dropzone-reviewed").parent

    # Below 1400px the upstream lanes collapse behind All Stages — and Building is
    # no longer exempt. Blocked tasks ride Building, so a stalled task is reachable
    # via the toggle at narrow rather than pinned visible.
    assert_includes designed_col[":class"].to_s, "max-[1399px]:hidden"
    assert_includes building_col[":class"].to_s, "max-[1399px]:hidden"
    # …while the last three lanes (reviewed · assembled · shipped) stay visible.
    refute_includes reviewed_col[":class"].to_s, "max-[1399px]:hidden"
  end
end
