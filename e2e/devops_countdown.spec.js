// [e2e] The live pill countdown (task live-build-countdown; AppDevopsStages::Eta,
// THE COUNTDOWN). e2e/seed.rb seeds Countdown Probe, a client app whose first
// version the launcher is building, with one earlier launcher run of six
// minutes. Its CTO chat's Building pill carries the expected finish (the run's
// start plus the launcher's own six minutes, not the hub's PR-work median) and
// ticks MM:SS down each second in tabular numerals; past the deadline it reads
// Any minute now, never a negative. The ticking text is hidden from screen
// readers, which read the rounded wait once. Under reduced motion it still ticks.
// The browser clock is driven from the pill's own deadline, so the seed's age
// does not matter.
//
// NOT @qa-readonly: it reads rows only e2e/seed.rb creates.
const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

const PILL = "[data-test='cto-chat-head'] [data-test='devops-stage'][data-stage='building'][data-state='live']";
const ETA = `${PILL} [data-test='devops-stage-eta'][data-devops-countdown]`;

for (const motion of [ "no-preference", "reduce" ]) {
  test(`the Building pill counts down to its deadline, then reads Any minute now (motion: ${motion})`, async ({ page }) => {
    const { pageErrors, report } = watchPageErrors(page);
    await page.emulateMedia({ reducedMotion: motion });
    await page.goto("/applications/countdown-probe/chat");
    const deadline = Date.parse(await page.locator(ETA).getAttribute("data-deadline"));
    expect(Number.isFinite(deadline), "the pill carries its expected finish").toBe(true);

    // Held at ninety seconds before the deadline; the ticker then runs only as the spec moves the clock.
    await page.clock.install({ time: deadline - 120_000 });
    await page.clock.pauseAt(deadline - 90_000);
    await page.reload();
    const eta = page.locator(ETA);
    await expect(eta).toHaveText("01:30");
    await expect(eta).toHaveCSS("font-variant-numeric", "tabular-nums");
    await expect(eta).toHaveAttribute("aria-hidden", "true");
    await expect(page.locator(`${PILL} .sr-only`)).toContainText(/min left|taking longer than usual/);

    await page.clock.runFor(1_000);
    await expect(eta).toHaveText("01:29");
    await page.clock.runFor(29_000);
    await expect(eta).toHaveText("01:00");

    await page.clock.runFor(61_000);
    await expect(eta).toHaveText("Any minute now");
    await expect(eta).toHaveAttribute("data-eta-kind", "long");
    await page.clock.runFor(120_000);
    await expect(eta, "never a negative").toHaveText("Any minute now");
    expect(pageErrors, report()).toEqual([]);
  });
}

test("the countdown runs from the launcher's own build time, and the row keeps its rounded words", async ({ page }) => {
  await page.goto("/applications/countdown-probe/chat");
  const deadline = Date.parse(await page.locator(ETA).getAttribute("data-deadline"));
  // The seeded build started a minute before the seed ran; the launcher's one earlier run took six minutes.
  const left = deadline - Date.now();
  expect(left, "about five minutes left at seed time, never the hub's ~30").toBeLessThanOrEqual(5 * 60_000 + 1_000);
  await expect(page.locator("[data-test='devops-task-status']").first()).toHaveText(/^Building · (~\d+ min left|taking longer than usual)$/);
});
