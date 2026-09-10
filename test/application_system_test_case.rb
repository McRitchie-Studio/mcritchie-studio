require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # How long to wait for a control to stop moving before clicking it.
  SETTLE_TIMEOUT = 5

  # How many times a SWALLOWED click is re-settled and re-dispatched before the helper
  # gives up and says so. Re-clicking is safe precisely because a swallowed click has no
  # effect BY DEFINITION — the element was never on the dispatched event's path, so its
  # handler did not run and cannot be run twice. A click that DID land is never retried.
  CLICK_ATTEMPTS = 3

  # An element's box, rounded, in ONE canonical shape. Shared so the guard tests can
  # compare the box this file CERTIFIED as settled against the box the click actually
  # landed in, instead of re-deriving the rounding and comparing two different numbers.
  BOX_JS = "[Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)].join(',')".freeze

  # Everything that can still resize the target, plus the target's own box, in one
  # round trip. `document.fonts.check` is asked about the element's OWN computed
  # font, because that is the face whose arrival moves THIS element — the global
  # `document.fonts.status` reads "loaded" while two dozen declared faces are still
  # "unloaded", since a face only loads when something needs it.
  SETTLE_PROBE_JS = <<~JS.freeze
    (function (el) {
      const r = el.getBoundingClientRect();
      const cs = getComputedStyle(el);
      let fontReady = true;
      try { fontReady = document.fonts.check(cs.fontWeight + " " + cs.fontSize + " " + cs.fontFamily); }
      catch (e) { fontReady = true; }
      const sheetsReady = Array.from(document.querySelectorAll('link[rel="stylesheet"]'))
        .every((l) => !!l.sheet);
      const settled = fontReady && sheetsReady && document.fonts.status === "loaded";
      return #{BOX_JS} + "|" + settled;
    })(arguments[0])
  JS

  # Put the element where the driver is about to click it. See click_when_settled for
  # why this has to happen BEFORE the geometry is certified rather than as part of the
  # click. `inline: 'nearest'` so a control inside a horizontally scrolling lane is not
  # yanked sideways as well.
  SCROLL_INTO_VIEW_JS = "arguments[0].scrollIntoView({ block: 'center', inline: 'nearest' });".freeze

  # Arm a one-shot witness on the ELEMENT so a swallowed click is a fact this file can
  # read, not a timing assumption it has to make.
  #
  # `click` is dispatched at the pointerdown/pointerup targets' common ancestor. When the
  # element moves out from under the pointer that ancestor is one of its PARENTS, and the
  # element is then not on the event path at all — so this listener does not fire, which
  # is exactly the "swallowed" condition. When both targets are descendants of the element
  # the ancestor is inside it, the event bubbles up THROUGH the element, its own handler
  # runs, and so does this one. The two cases are therefore distinguished exactly, with no
  # reference to how fast the runner is.
  CLICK_WITNESS_JS = <<~JS.freeze
    (function (el) {
      if (el.__clickWitness) { el.removeEventListener('click', el.__clickWitness); }
      window.__clickLanded = false;
      el.__clickWitness = function () { window.__clickLanded = true; };
      el.addEventListener('click', el.__clickWitness);
    })(arguments[0])
  JS

  # Click a control only once it has STOPPED MOVING — and prove the click landed.
  #
  # A synthesized click is dispatched at fixed viewport COORDINATES: the driver
  # hit-tests the element, then sends pointerdown and pointerup at that point. If the
  # page reflows in between, pointerup lands on a DIFFERENT element, and the browser
  # fires `click` on the two targets' nearest COMMON ANCESTOR — never on the button.
  # No error is raised. The handler simply never runs, and the test fails later, on
  # whatever it asserted about the click's effect.
  #
  # TWO THINGS MOVE A CONTROL OUT FROM UNDER THE POINTER, and this helper needs both
  # halves because each defeats the other's guard.
  #
  #   THE WEBFONT. Page text is set in Montserrat, fetched from fonts.googleapis.com.
  #   That stylesheet blocks the load event but the font FILES do not, so they land
  #   after `visit` returns and every glyph is re-measured. This is the measured cause
  #   of close-board-filter-flake, which reddened three unrelated PRs across two
  #   sessions in one day, always on the same assertion. Captured event sequence for a
  #   filter chip that reflowed under the pointer:
  #
  #     pointerdown -> SPAN "rolio"        (the chip)
  #     pointerup   -> SPAN "Apps"         (the row label; the chip has moved)
  #     click       -> DIV                 (their common ancestor)
  #
  #   Locally the font is cached and it never reproduces; on a CI runner it is a live
  #   fetch. Guarded by await_settled_geometry, whose probe waits on that face.
  #
  #   THE DRIVER'S OWN SCROLL. `element.click` SCROLLS the element into view as its
  #   first step, and on this app a scroll is not free: the sticky nav's hysteresis
  #   collapses the header and every element below it slides UP. Measured 2026-09-09 on
  #   /deployments at a 700x1000 window — the Workflows "Show All" toggle, a 13px-tall
  #   control:
  #
  #     scroll lands   scrollY 0 -> 472   header 134px   toggle y 422   0 animations
  #     +80ms                             header 114px   toggle y 402
  #     +160ms                            header 102px   toggle y 390   (settled)
  #
  #   A 32px slide under a 13px button — two and a half button-heights — beginning about
  #   one frame AFTER the scroll, with `document.getAnimations()` empty at the instant the
  #   scroll lands, so there is no pre-signal to read. This is what reddened
  #   chip-fit-reveal-races-runner: on three runs of ONE unchanged SHA the system suite
  #   passed at 24.5s and failed at 30.5s and 40.5s, because a slower runner widens the
  #   pointerdown/pointerup gap until it straddles a step of that slide.
  #
  # WHY SCROLLING FIRST IS THE FIX AND A BIGGER TIMEOUT IS NOT. Certifying the box and
  # then letting the driver scroll measures the element in a coordinate frame the click
  # is about to LEAVE: at scrollY 0 the box is genuinely, repeatably stable, and that
  # fact says nothing whatever about scrollY 472. The wait is satisfied by the state
  # being left behind, so no amount of it can help. Entering the click's frame first
  # puts the collapse INSIDE the settle loop's window, where it is what the loop is for.
  #
  # AND THE SETTLE LOOP ALONE IS STILL NOT ENOUGH, which is the lesson of the fix before
  # this one. It clears on two identical consecutive samples, so a runner starved badly
  # enough to stall frames past the 50ms sample interval reads the same box twice before
  # the collapse's first step lands — the guard cannot tell a page that has settled from
  # a page that has not moved YET. So the click is WITNESSED rather than assumed: a click
  # that never reached the element is retried in the frame it will actually land in, and
  # a control that swallows every attempt fails here, naming itself, instead of surfacing
  # as whatever the caller asserted next.
  #
  # Use this instead of `find(...).click` for any control clicked soon after a page
  # load. `find(...).click` remains correct once the page has been interacted with.
  #
  # GUARDED BY, and both are load-bearing — neither can see the other's blind spot:
  #   test/system/board_filter_click_stability_test.rb — the reflow-under-pointer half
  #   test/system/workflows_card_chip_fit_test.rb      — the certified-frame half
  def click_when_settled(selector, settle_timeout: SETTLE_TIMEOUT, attempts: CLICK_ATTEMPTS, **find_options)
    element = find(selector, **find_options)

    attempts.times do |attempt|
      execute_script(SCROLL_INTO_VIEW_JS, element)
      @last_settled_box = await_settled_geometry(element, timeout: settle_timeout)
      execute_script(CLICK_WITNESS_JS, element)
      element.click
      return element unless click_was_swallowed?

      next unless attempt == attempts - 1

      flunk "#{element.tag_name}[#{selector}] swallowed #{attempts} clicks: the element was never " \
            "on the dispatched click's path, so its handler never ran. pointerdown and pointerup " \
            "landed on different elements and the browser fired `click` on their common ancestor. " \
            "Its box was certified settled at #{@last_settled_box} in the frame it was clicked in, " \
            "so something is still moving it — check for a scroll-driven header, a transition, or " \
            "a late-arriving webfont. THIS IS NOT A VERDICT ABOUT THE CONTROL'S BEHAVIOUR."
    end
  end

  # The box click_when_settled last certified as settled, "x,y,width,height". The guard
  # tests compare it against the box the click actually landed in — the two being equal
  # is the property that makes the certification mean anything.
  attr_reader :last_settled_box

  # True ONLY when the witness is still standing there to report that the click never
  # reached the element. Every other reading means DO NOT RETRY, and the distinction is
  # load-bearing rather than defensive: retrying is safe only for a click that provably
  # did nothing. A click that navigated away takes the witness with it, so the global
  # reads nil on the new document — and re-clicking THAT would replay a real interaction
  # against a page that has already moved on.
  def click_was_swallowed?
    evaluate_script("window.__clickLanded") == false
  rescue StandardError
    false
  end

  # Block until the element's box is identical across two consecutive samples AND
  # nothing is left in flight that could still resize it. Both halves are load-
  # bearing: stability alone would clear a box that has simply not been re-measured
  # yet, and readiness alone would clear a box mid-animation.
  #
  # Returns the settled box so the caller can report — and a guard test can pin — WHICH
  # box was certified. It samples getBoundingClientRect, which is viewport-relative, so
  # a box is only meaningful together with the scroll position it was taken at: certify
  # in the frame the click will happen in, never before the scroll that gets there.
  def await_settled_geometry(element, timeout: SETTLE_TIMEOUT)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    previous_box = nil

    loop do
      box, settled = evaluate_script(SETTLE_PROBE_JS, element).to_s.split("|")
      return box if settled == "true" && previous_box == box

      previous_box = box
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        flunk "#{element.tag_name} never stopped moving within #{timeout}s (last box #{box}, " \
              "settled=#{settled}). Clicking it now would dispatch pointerdown and pointerup at " \
              "different elements and the click would be silently swallowed."
      end
      sleep 0.05
    end
  end
end
