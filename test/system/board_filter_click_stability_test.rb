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

      const jitter = () => {
        if (!window.__settling.open) { label.style.letterSpacing = '0px'; return; }
        const elapsed = performance.now() - window.__settling.t0;
        if (elapsed >= windowMs) { window.__settling.open = false; label.style.letterSpacing = '0px'; return; }
        label.style.letterSpacing = (elapsed / windowMs * 12).toFixed(2) + 'px';
        requestAnimationFrame(jitter);
      };
      requestAnimationFrame(jitter);

      document.addEventListener('pointerdown', () => {
        window.__settling.clickedAt = Math.round(performance.now() - window.__settling.t0);
        if (!window.__settling.open) return;
        label.style.letterSpacing = '24px';
        row.getBoundingClientRect();
      }, true);
    JS
  end

  def clicked_after_settling_ms
    evaluate_script("window.__settling.clickedAt").to_i
  end
end
