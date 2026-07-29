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

    # The board is rebased onto the studio/board primitive; its studioBoard factory
    # (homed in the layout) sources the from/to from the DROPZONES (evt.from /
    # evt.to), never the card's data-stage.
    assert_includes js, "var fromZone = evt.from;"
    assert_includes js, "var toZone = evt.to;"
    # A same-zone drop is a pure reorder — `moved` is false, so no stage PATCH fires;
    # only a cross-column drop moves the card. An in-place reorder cannot change stage.
    assert_includes js, "var moved = fromZone !== toZone;"
    assert_includes js, "if (moved) {"
    # No stranding revert that looks up a card's own (old) stage dropzone.
    refute_includes js, "dropzone-' + oldStage"
  end

  test "the Build board subscribes live so blocked transitions patch into Building" do
    get tasks_path
    assert_response :success

    # The primitive renders exactly one turbo_stream_from(live_channel) and wires the
    # studioBoard factory live, so a broadcast blocked-transition patches Building.
    assert_select "turbo-cable-stream-source", count: 1
    board = css_select("[data-test='studio-board']").first
    assert board, "the tasks board renders through the studio/board primitive"
    assert_includes board["x-data"].to_s, %q("live":true), "the board is wired live"
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
