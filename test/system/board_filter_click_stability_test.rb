require "application_system_test_case"

# [e2e] The GUARD behind click_when_settled, asserted as the effect it exists to
# produce: a chip clicked while the page is still reflowing does not toggle.
#
# WHY THIS TEST IS SHAPED LIKE THIS. The production failure (close-board-filter-flake)
# is a race — a webfont arriving from fonts.googleapis.com re-measures every glyph, and
# if that lands between the driver's pointerdown and pointerup the browser fires `click`
# on the two targets' common ancestor instead of the button. A racy failure cannot be
# asserted by waiting for it to happen; it reproduced three times in one CI day and
# never once in five local runs. So the trigger is made DETERMINISTIC here: the page is
# put into a settling state that moves the chip every frame and reflows it under any
# pointerdown, for a fixed window, then stops. That is the same event the font causes,
# on a clock instead of a network.
#
# THE MUTATION THIS TEST IS BUILT TO CATCH: swap click_when_settled for a plain
# find(...).click and this test goes red on the aria-pressed assertion — the exact
# signature CI produced, where the chip is left un-pressed and the card never hides.
class BoardFilterClickStabilityTest < ApplicationSystemTestCase
  SETTLING_MS = 600

  test "[e2e] a chip click waits for the layout to stop moving" do
    rolio = Task.create!(
      title: "rolio settling board card", stage: "building",
      metadata: { "devops" => { "repositories" => ["rolio"] } }
    )

    visit tasks_path
    assert_selector "[data-test='kanban-board'][data-alpine-ready='true']"
    assert_selector "#card-#{rolio.slug}", visible: true

    start_settling_window

    click_when_settled("[data-test='board-filter-row'] button", text: "rolio", match: :first)

    # The chip's own state first: it is what distinguishes a swallowed click from a
    # filter that toggled but failed to reach the card.
    assert_selector "[data-test='board-filter-row'] button[aria-pressed='true']", text: "rolio",
                    wait: 5
    assert_no_selector "#card-#{rolio.slug}", visible: true

    # The window really was open while the click was pending — otherwise this test
    # would still pass with the guard removed, and prove nothing.
    assert_operator clicked_after_settling_ms, :>=, SETTLING_MS,
                    "the click was dispatched before the settling window closed"
  end

  # THE REGRESSION GUARD for the fix above, asserted as the PROPERTY rather than the
  # implementation: while the window is open, the chip's box must keep changing even
  # when no frame ever runs.
  #
  # It exists because the obvious "cleanup" is to put the rAF jitter back — it reads
  # more like a test and less like a stylesheet. Measured, that revert costs 6 of every
  # 9 `test`-job failures in this repo. With rAF disabled outright, the CSS-driven
  # window still advanced the chip 122 -> 165px across ten 50ms samples with ZERO
  # consecutive duplicates; the rAF version, merely throttled to 120ms, produced a
  # duplicate on the FIRST pair and failed the test above with CI's exact message.
  test "[e2e] the settling window moves the chip without any frames" do
    Task.create!(
      title: "rolio settling board card", stage: "building",
      metadata: { "devops" => { "repositories" => ["rolio"] } }
    )

    visit tasks_path
    assert_selector "[data-test='kanban-board'][data-alpine-ready='true']"

    # The harshest starvation there is, and a fair model of a loaded runner: a page
    # where requestAnimationFrame never calls anything back.
    execute_script("window.requestAnimationFrame = function () { return 0; };")

    start_settling_window
    chip = find("[data-test='board-filter-row'] button", text: "rolio", match: :first)

    boxes = 6.times.map do
      x = evaluate_script(
        "(function (el) { return Math.round(el.getBoundingClientRect().x); })(arguments[0])", chip
      )
      sleep 0.05
      x
    end

    duplicates = boxes.each_cons(2).count { |a, b| a == b }
    assert_equal 0, duplicates,
                 "the chip stopped moving while the settling window was open and no frames were " \
                 "running (x samples: #{boxes.inspect}). await_settled_geometry polls geometry every " \
                 "50ms and clears on two identical samples, so a frame-driven window lets it clear " \
                 "early, the click lands inside the window, and the pointerdown handler swallows it. " \
                 "This is the flake — do not drive the window from requestAnimationFrame."
  end

  private

  # Stand in for the webfont swap. Two halves, both required: the chip MOVES every
  # frame -- monotonically, the way a one-way font swap widens text, so no two samples of
  # a settling box are ever equal -- so a geometry guard can see the page is not settled;
  # and a pointerdown while
  # the window is open reflows the row synchronously, which is what actually splits
  # pointerdown from pointerup. After SETTLING_MS the layout is final, exactly as it is
  # once the font has arrived.
  def start_settling_window
    execute_script(<<~JS, SETTLING_MS)
      const windowMs = arguments[0];
      const row = document.querySelector("[data-test='board-filter-row']");
      const label = row.querySelector('span');
      window.__settling = { open: true, t0: performance.now(), clickedAt: null };

      // THE MOVEMENT IS DRIVEN BY A CSS ANIMATION, NOT BY requestAnimationFrame, and
      // that is the whole fix for this test's flakiness.
      //
      // WHAT WAS WRONG, MEASURED. await_settled_geometry clears when `settled` is
      // true AND the box is unchanged since the previous sample, polling every 50ms.
      // A jitter driven by rAF only moves the label when a FRAME RUNS. On a loaded CI
      // runner frames starve, so two consecutive polls can see an identical box while
      // the page is still very much moving — the guard clears, the click lands inside
      // the window, the pointerdown handler below swallows it exactly as designed, and
      // the aria-pressed assertion fails. Reproduced locally by advancing the old
      // jitter every 120ms instead of every frame: the first two samples (13ms and
      // 70ms) came back identical and the test failed with CI's exact message. That
      // is 6 of the last 9 `test`-job failures across all branches, and it reddens
      // `accepted` itself.
      //
      // WHY A CSS ANIMATION FIXES IT. getBoundingClientRect() forces a style and
      // layout flush, and the browser resolves an animated property at the CURRENT
      // TIME when it does — so every poll observes a different box whether or not a
      // frame has painted in between. The signal stops being frame-sampled, which is
      // the property the guard needs and the rAF version could not offer at any
      // cadence.
      //
      // Do NOT return this to rAF to "make it deterministic". rAF is precisely the
      // thing that is not deterministic on a loaded runner.
      const style = document.createElement('style');
      style.textContent =
        '@keyframes studio-settling { from { letter-spacing: 0px } to { letter-spacing: 12px } }' +
        '.studio-settling { animation: studio-settling ' + windowMs + 'ms linear forwards }';
      document.head.appendChild(style);
      label.classList.add('studio-settling');

      // The window closes on the CLOCK, not on a frame having run — see the note on
      // the pointerdown handler below, which is the other half of the same lesson.
      setTimeout(() => {
        window.__settling.open = false;
        label.classList.remove('studio-settling');
        label.style.letterSpacing = '0px';
        style.remove();
      }, windowMs);

      // The window closes on the CLOCK, not on a frame having run. Reading the flag
      // the jitter loop maintains would leave a gap one frame wide: the box stops
      // changing at the LAST jitter frame, so a guard polling geometry can see it
      // settle and click before a later frame flips the flag. On a loaded runner
      // with slow frames that gap is real, and this test would go red for a reason
      // that has nothing to do with the guard it exists to pin.
      document.addEventListener('pointerdown', () => {
        const elapsed = performance.now() - window.__settling.t0;
        window.__settling.clickedAt = Math.round(elapsed);
        if (elapsed >= windowMs) return;
        label.style.letterSpacing = '24px';
        row.getBoundingClientRect();
      }, true);
    JS
  end

  def clicked_after_settling_ms
    evaluate_script("window.__settling.clickedAt").to_i
  end
end
