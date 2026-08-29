require "test_helper"

# Component-tier contract for task stop-headers-chasing-navbar. Sibling to
# bar_stack_adoption_test, which pins the OTHER half of this layout's chrome.
#
# THE DEFECT: the operator reported the navbar "randomly flickering" while
# scrolled down. The navbar was innocent — parked at scrollY 600 for 15 seconds
# it logged zero mutations and a constant height. What flickered was everything
# positioned OFF it. The app-ladder strip and the board's stage headers each
# wrote their own top from a MEASURED read of the header, taken while the header
# was still easing through a 300ms transition, so both chased it a frame behind
# through 17 intermediate values. It read as random because it depended on where
# in the ease you happened to scroll again.
#
# Measured A/B on the same page — scroll, then stop and watch:
#   before   header drifts 3.1px after the gesture ends, stage headers 3px
#   after    0px and 0px
#
# The fix has two halves and the ORDER matters: the navbar adopts the engine's
# scroll-linked collapse so it stops easing, and the dependents stop measuring
# it at all — they read the pinned-stack properties the engine publishes. Doing
# only the second would leave them tracking a header that still eases.
class PinnedStackAdoptionTest < ActiveSupport::TestCase
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")
  STRIP  = Rails.root.join("app/views/tasks/_app_ladder_row.html.erb")
  BOARD  = Rails.root.join("app/views/tasks/_deploy_board.html.erb")

  # The release the pinned-stack publisher landed in. A NUMBER, not a string:
  # below it neither --pin-nav-bottom nor --pin-apps-bottom is ever published,
  # every var() falls back to 0px, and the strip and every stage header pile up
  # at the top of the viewport underneath the navbar.
  PINNED_STACK_FROM = Gem::Version.new("0.65")

  test "the resolved engine publishes the pinned stack this app positions off" do
    resolved = Gem.loaded_specs["studio-engine"].version

    assert_operator resolved, :>=, PINNED_STACK_FROM,
                    "studio-engine #{resolved} predates the pinned-stack publisher; the strip " \
                    "and the stage headers would fall back to top 0 under the navbar"
  end

  test "the navbar is scroll-linked rather than eased on a clock" do
    layout = LAYOUT.read

    assert_includes layout, 'x-data="navCollapse()"',
                    "the header must own the engine's scroll-linked collapse"
    assert_includes layout, 'data-pin="nav"',
                    "the header must publish its edge, or nothing below can position off it"
    assert_includes layout, "nav-shell", "the header is the --nav-p scope"

    # THE THING THAT CAUSED THE FLICKER. A threshold feeding a timed transition
    # keeps the header moving after the gesture ends, and anything reading its
    # geometry lags a frame behind for the whole ease.
    refute_match(/@scroll\.window/, layout,
                 "a per-event scroll threshold is what the coalesced collapse replaced")
    refute_match(/x-bind:class="scrolled \?/, layout,
                 "size swaps on a boolean put the collapse back on a clock")
  end

  # The engine's mobile band stacks the title into a column under 768px; this
  # navbar never stacked (measured: collapsed title 24px -> 44px when it did).
  test "the title stays one line under 768px, as the threshold build was" do
    css = Rails.root.join("app/assets/tailwind/application.css").read
    assert_match(/@media \(max-width: 767px\)\s*\{\s*\.nav-shell \.nav-title\s*\{[^}]*flex-direction:\s*row/m, css,
                 "the hub's mobile title must stay in row direction")
  end

  # THE POINT OF THE WHOLE TASK: the dependents no longer measure the header.
  test "the strip and the stage headers position from the pinned stack alone" do
    strip = STRIP.read
    board = BOARD.read

    assert_match(/top:\s*var\(--pin-nav-bottom/, strip,
                 "the strip must take its top from the published edge, not a measured number")
    assert_match(/top:\s*max\(var\(--pin-nav-bottom[^)]*\),\s*var\(--pin-apps-bottom/, board,
                 "the stage headers must compose the stack in CSS; max() lets a hidden strip drop out")
    assert_includes strip, 'data-pin="apps"',
                    "the strip is itself a layer, or the stage headers cannot stack onto it"

    # And the machinery that did the measuring is GONE rather than bypassed — a
    # leftover writer would fight the CSS every frame.
    refute_match(/:style="\{\s*top:\s*offset/, strip, "the strip must no longer write its own top")
    refute_match(/:style="\{\s*top:\s*laneTop/, board, "the stage headers must no longer write their own top")
    refute_match(/^\s*laneTop:/, board, "laneTop state must go with the writer that used it")
    refute_match(/watchStrip\(/, board, "the strip-observing machinery must be gone")
    refute_match(/_laneRo\.observe\(header\)/, board,
                 "observing the header duplicates a measurement the engine already coalesces")
  end
end
