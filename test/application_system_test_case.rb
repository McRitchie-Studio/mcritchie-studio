require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # How long to wait for a control to stop moving before clicking it.
  SETTLE_TIMEOUT = 5

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
      return [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)]
        .join(",") + "|" + settled;
    })(arguments[0])
  JS

  # Click a control only once it has STOPPED MOVING.
  #
  # A synthesized click is dispatched at fixed viewport COORDINATES: the driver
  # hit-tests the element, then sends pointerdown and pointerup at that point. If the
  # page reflows in between, pointerup lands on a DIFFERENT element, and the browser
  # fires `click` on the two targets' nearest COMMON ANCESTOR — never on the button.
  # No error is raised. The handler simply never runs, and the test fails later, on
  # whatever it asserted about the click's effect.
  #
  # This is not hypothetical: it is the measured cause of close-board-filter-flake,
  # which reddened three unrelated PRs across two sessions in one day, always on the
  # same assertion. Captured event sequence for a filter chip that reflowed under the
  # pointer:
  #
  #   pointerdown -> SPAN "rolio"        (the chip)
  #   pointerup   -> SPAN "Apps"         (the row label; the chip has moved)
  #   click       -> DIV                 (their common ancestor)
  #
  # What moves it: page text is set in Montserrat, fetched from fonts.googleapis.com.
  # That stylesheet blocks the load event but the font FILES do not, so they land
  # after `visit` returns and every glyph is re-measured — which is exactly the window
  # a test spends asserting readiness, finding a control, and clicking it. On this
  # machine the font is already cached and the failure never appears; on a CI runner
  # it is a live network fetch. That asymmetry is why five local reproductions of this
  # flake all came back green.
  #
  # Use this instead of `find(...).click` for any control clicked soon after a page
  # load. `find(...).click` remains correct once the page has been interacted with.
  def click_when_settled(selector, settle_timeout: SETTLE_TIMEOUT, **find_options)
    element = find(selector, **find_options)
    await_settled_geometry(element, timeout: settle_timeout)
    element.click
    element
  end

  # Block until the element's box is identical across two consecutive samples AND
  # nothing is left in flight that could still resize it. Both halves are load-
  # bearing: stability alone would clear a box that has simply not been re-measured
  # yet, and readiness alone would clear a box mid-animation.
  def await_settled_geometry(element, timeout: SETTLE_TIMEOUT)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    previous_box = nil

    loop do
      box, settled = evaluate_script(SETTLE_PROBE_JS, element).to_s.split("|")
      return true if settled == "true" && previous_box == box

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
