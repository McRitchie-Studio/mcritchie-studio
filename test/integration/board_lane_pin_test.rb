# frozen_string_literal: true

require "test_helper"

# The swim-lane headers PIN — each stage keeps its name and count on screen while its
# cards scroll under it, stacked beneath the app-ladder strip.
#
# WHAT THIS TIER CAN PROVE, and what it deliberately leaves to e2e/deployments_lane_pin:
# the header is `position: sticky`, it takes its top from the MEASURED stack rather than
# a hard-coded number, and the lane row does not carry a static horizontal scroller.
# That last one is the whole feature in one assertion — a sticky child inside an
# `overflow-x: auto` ancestor sticks to a scrollport that never scrolls vertically, so
# it silently does nothing. Whether the headers END UP at the right y is geometry, and
# geometry is settled in a browser.
class BoardLanePinTest < ActionDispatch::IntegrationTest
  setup { get deployments_path }

  test "every lane header is sticky and named by its stage" do
    assert_response :success

    headers = css_select("[data-test='stage-header']")
    assert_equal Task::DEPLOYMENTS_BOARD_STAGES.size, headers.size,
                 "one pinned header per lane"

    stages = headers.map { |el| el["data-stage"] }
    assert_equal Task::DEPLOYMENTS_BOARD_STAGES, stages, "the headers read across the board"

    headers.each do |el|
      assert_includes el["class"], "sticky", "#{el['data-stage']} header must pin"
      assert_includes el["class"], "z-30",
                      "under the ladder strip (z-40) and the site nav (z-50), over the cards"
    end
  end

  # MEASURED, NEVER HARD-CODED. The site header shrinks on scroll and the ladder strip
  # comes and goes, so a fixed offset would leave the lane names floating in a gap or
  # tucked under the nav.
  test "the lane header takes its top from the measured stack" do
    header = css_select("[data-test='stage-header']").first

    assert_equal "{ top: laneTop + 'px' }", header[":style"]
    assert_includes response.body, "this.laneTop = Math.round(base + stack)",
                    "laneTop is the site header's bottom plus the pinned strip's height"
  end

  # THE ONE THAT MATTERS. A scroll-container ancestor makes `position: sticky` a no-op
  # here, so the lane row may only carry the scroller while it is MEASURED to need one —
  # never as a static class.
  test "the lane row carries no static horizontal scroller" do
    lanes = css_select("[data-test='kanban-lanes']").first
    assert lanes, "the board must name its lane row"

    assert_not_includes lanes["class"].to_s, "overflow-x-auto",
                        "a static scroller here un-sticks every lane header"
    assert_equal "laneScroll ? 'sm:overflow-x-auto' : ''", lanes[":class"]
    assert_includes response.body, "lanes.scrollWidth > lanes.clientWidth + 1",
                    "the scroller switches itself on from a measurement, not a breakpoint"
  end

  # THE BROADCAST REGRESSION. app-ladder-row is replaced wholesale and the strip rides inside
  # it, so an init-bound observation watches a detached node from the first broadcast on.
  test "the lane observer follows the strip across a broadcast" do
    assert_includes response.body, "if (!this._laneRo || strip === this._laneStrip) return;"
    assert_includes response.body, "this._laneRo.unobserve(this._laneStrip);"
    assert_equal 2, response.body.scan("this.watchStrip(strip);").size,
                 "init AND every measure route through the one place that observes"
  end

  # The header still carries what it always did — the stage label and its count badge —
  # because pinning it is a placement change and nothing more.
  test "a pinned header keeps its label and its count" do
    header = css_select("[data-test='stage-header'][data-stage='shipped']").first

    assert_includes header.text, Task::STAGE_LABELS.fetch("shipped")
    assert_select "[data-test='stage-header'][data-stage='shipped'] [data-stage-count='shipped']", 1
  end
end
