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

  # The release the COMPOSED pinned stack landed in. A NUMBER, not a string:
  # below it --pin-stack-bottom is never published, every var() falls back to
  # 0px, and every stage header piles up at the top of the viewport underneath
  # the navbar.
  #
  # It moved 0.65 -> 0.72.3 with the adoption above. 0.65 shipped the per-layer
  # properties this app used to compose itself with a max(); 0.72.3 is where the
  # publisher started composing the stack ITSELF, and where it began writing
  # inside its ResizeObserver callback instead of a frame later. Leaving the floor
  # at 0.65 would let a resolver serve an engine that publishes neither name while
  # every assertion below — which reads SOURCE, not a running page — stayed green.
  PINNED_STACK_FROM = Gem::Version.new("0.72.3")

  test "the resolved engine publishes the pinned stack this app positions off" do
    resolved = Gem.loaded_specs["studio-engine"].version

    assert_operator resolved, :>=, PINNED_STACK_FROM,
                    "studio-engine #{resolved} predates the pinned-stack publisher; the stage " \
                    "headers would fall back to top 0 under the navbar"
  end

  test "the navbar is scroll-linked rather than eased on a clock" do
    layout = LAYOUT.read
    navbar = Pathname(Gem.loaded_specs["studio-engine"].full_gem_path).join("app/views/layouts/_navbar.html.erb").read

    assert_includes layout, "hub_navbar(", "the header must be the engine's navbar"
    assert_includes navbar, 'data-studio-controller="nav-collapse"',
                    "the header must own the engine's scroll-linked collapse"
    assert_includes navbar, 'data-pin="nav"',
                    "the header must publish its edge, or nothing below can position off it"
    assert_includes navbar, "nav-shell", "the header is the --nav-p scope"

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
  # The app-ladder strip was the other dependent until the operator retired it on
  # 2026-09-26; the stage headers are the one left, and nothing may re-add a layer
  # they would have to know about.
  test "the stage headers position from the pinned stack alone" do
    strip = STRIP.read
    board = BOARD.read

    assert_match(/top:\s*var\(--pin-stack-bottom/, board,
                 "the stage headers must read the engine's ONE composed value")
    refute_match(/max\(var\(--pin-/, board,
                 "the board may not compose the stack itself — see the engine's publisher")

    # And the machinery that did the measuring is GONE rather than bypassed — a
    # leftover writer would fight the CSS every frame.
    refute_match(/:style="\{\s*top:\s*laneTop/, board, "the stage headers must no longer write their own top")
    refute_match(/^\s*laneTop:/, board, "laneTop state must go with the writer that used it")
    refute_match(/watchStrip\(/, board, "the strip-observing machinery must be gone")
    refute_match(/_laneRo\.observe\(header\)/, board,
                 "observing the header duplicates a measurement the engine already coalesces")

    # The retired strip left no layer, no store and no scroll handler behind.
    refute_includes strip, 'data-pin="apps"', "the applications strip is retired"
    refute_match(/appLadder/, strip + board, "the strip's store must go with the strip")
  end
end
