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

  # COMPOSED, NEVER MEASURED HERE. The site header shrinks on scroll and the ladder
  # strip comes and goes, so a fixed offset would leave the lane names floating in a
  # gap or tucked under the nav. This used to be solved by MEASURING both and summing
  # them into laneTop — and that is what made these headers chase the site header
  # through every intermediate height of its collapse, a frame behind, for the whole
  # ease (task stop-headers-chasing-navbar; the drift after a gesture ended measured
  # 3px, now 0px). Each layer publishes its own edge through the engine's pinned stack
  # and the sum is a CSS expression, so there is nothing left to lag.
  test "the lane header composes its top from the pinned stack" do
    header = css_select("[data-test='stage-header']").first

    assert_match(/top:\s*max\(var\(--pin-nav-bottom[^)]*\),\s*var\(--pin-apps-bottom/,
                 header["style"].to_s,
                 "the lane header must compose the stack in CSS")
    assert_nil header[":style"],
               "an Alpine style bind would fight the CSS and put the lag back"

    # max(), NOT a declared order: a hidden strip measures 0 and drops out on its own,
    # so nothing here has to know which layer sits above which.
    assert_not_includes response.body, "this.laneTop",
                        "laneTop state must go with the writer that used it"
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

  # THE BROADCAST REGRESSION, now handled a layer down. app-ladder-row is replaced
  # wholesale and the strip rides inside it, so an init-bound observation watches a
  # detached node from the first broadcast on. This board used to answer that itself,
  # with watchStrip re-observing from init and from every measure.
  #
  # It no longer observes the strip at all: the strip is a data-pin layer, and the
  # engine's publisher REBUILDS its registry from the document on
  # turbo:before-stream-render — so a replaced node is re-registered rather than
  # re-observed by hand. The regression is still guarded; it is guarded once, for
  # every consumer, instead of once per board.
  #
  # What this app still owes is the OPT-IN. Drop data-pin and the strip silently
  # leaves the registry, publishes nothing, and every lane header falls back to the
  # site header's edge alone — which looks almost right and is wrong by the strip's
  # height the moment it shows.
  test "the strip opts into the pinned stack so a broadcast cannot strand it" do
    strip = css_select("[data-test='app-ladder-pinned']").first
    assert strip, "the board must render the pinned strip"

    assert_equal "apps", strip["data-pin"],
                 "the strip must be a named layer, or the lane headers cannot stack onto it"
    assert_not_includes response.body, "watchStrip",
                        "a second observer on the strip duplicates the engine's registry"
    assert_not_includes response.body, "_laneRo.observe(header)",
                        "observing the site header duplicates a measurement the engine coalesces"
  end

  # The header still carries what it always did — the stage label and its count badge —
  # because pinning it is a placement change and nothing more.
  test "a pinned header keeps its label and its count" do
    header = css_select("[data-test='stage-header'][data-stage='shipped']").first

    assert_includes header.text, Task::STAGE_LABELS.fetch("shipped")
    assert_select "[data-test='stage-header'][data-stage='shipped'] [data-stage-count='shipped']", 1
  end
end
