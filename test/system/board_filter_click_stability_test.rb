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

    # And the window really MOVED the box while it was open. Without this, a fixture
    # whose motion silently stopped — the flake that made this file 3-of-4 red in CI —
    # would leave the test green and the guard unexercised.
    assert_operator distinct_settling_widths, :>, 1,
                    "the settling fixture never moved the row: the guard was never asked to wait"
  end

  # THE REGRESSION GUARD for the fixture above, asserted as the PROPERTY rather than
  # the implementation: while the window is open, the chip's box must keep changing
  # even when no frame ever runs.
  #
  # It exists because the obvious "cleanup" is to put the rAF jitter back — a frame
  # loop reads more like animation code than a bare setInterval does, so the revert is
  # the tidy-looking change. Measured, that revert costs 6 of every 9 `test`-job
  # failures in this repo, on feature branches and on `accepted` itself, always with
  # the same message: expected to find css button[aria-pressed='true'] but there were
  # no matches. The test above cannot catch the revert on its own — it asserts the
  # fixture MOVED, and a frame-driven fixture does move, right up until the runner
  # starves. This one removes the frames and asserts the motion survives, which is the
  # property the guard downstream actually depends on.
  #
  # It bites by construction: stub rAF to a no-op, put the jitter back on rAF, and the
  # label never widens, so all six samples are identical and this test goes red.
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

  # Stand in for the webfont swap. Two halves, both required: the chip MOVES for the
  # whole window -- monotonically, the way a one-way font swap widens text, so no two
  # samples of a settling box are ever equal -- so a geometry guard can see the page is
  # not settled; and a pointerdown while the window is open reflows the row
  # synchronously, which is what actually splits pointerdown from pointerup. After
  # SETTLING_MS the layout is final, exactly as it is once the font has arrived.
  #
  # THE MOTION RUNS ON A TIMER, NOT ON FRAMES, and that is the fix for this file's own
  # flake. It was requestAnimationFrame, and this test then went red 3 of 4 runs in CI
  # while passing every local run: a loaded runner (or a throttled headless renderer)
  # stalls frames past the guard's 50ms sample interval, so the box stops changing
  # while the window is still open. The guard reads two identical samples, clicks, the
  # pointerdown handler below reflows the row, and the click is swallowed -- the chip
  # left un-pressed, which is exactly the failure this test exists to CATCH. A fixture
  # that cannot move the box is indistinguishable, to the guard, from a page that has
  # settled; the whole point of this window is that those two must never look alike.
  #
  # The window's CLOSE was already moved off frames onto the clock for the same reason
  # (see below); this is the other half of that lesson.
  def start_settling_window
    execute_script(<<~JS, SETTLING_MS)
      const windowMs = arguments[0];
      const row = document.querySelector("[data-test='board-filter-row']");
      const label = row.querySelector('span');
      window.__settling = { open: true, t0: performance.now(), clickedAt: null };

      // Every sample the guard takes must differ from the last, so the tick has to
      // beat its 50ms interval with room to spare — and it must keep ticking when
      // the renderer is starved, which is why this is a timer and not a frame.
      // Measure what the GUARD measures — the button it is about to click — not the
      // row, which is full-width and never changes. (Measured: sampling the row
      // recorded ONE width all window long, which is the vacuous-green this
      // assertion exists to prevent.)
      window.__settling.boxes = new Set();
      const chip = row.querySelector('button');
      const measure = () => {
        const r = chip.getBoundingClientRect();
        window.__settling.boxes.add(Math.round(r.x) + "," + Math.round(r.width));
      };

      const jitter = () => {
        const elapsed = performance.now() - window.__settling.t0;
        if (!window.__settling.open || elapsed >= windowMs) {
          window.__settling.open = false;
          label.style.letterSpacing = '0px';
          clearInterval(window.__settling.timer);
          return;
        }
        label.style.letterSpacing = (elapsed / windowMs * 12).toFixed(2) + 'px';
        measure();
      };
      window.__settling.timer = setInterval(jitter, 20);
      jitter();

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

  # How many DISTINCT row widths the fixture actually produced while the window was
  # open. Asserted because a fixture that fails to move the box turns this test into
  # a green that proves nothing: the guard would clear a page it never had to wait
  # for, and the click would land in a settled layout by luck. One width means the
  # motion never happened — a FIXTURE failure, and it should read as one.
  def distinct_settling_widths
    evaluate_script("window.__settling.boxes.size").to_i
  end
end
