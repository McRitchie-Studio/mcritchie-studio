const { test, expect } = require("@playwright/test");

// [e2e] THE OPERATOR-WINDOW COUNTDOWN RENDERS AND TICKS. A card whose task waits on
// the operator (a `waiting` UI approval, or an `Escalated:` dependency block) wears
// a countdown chip beside its slug row (tasks/_window_chip); the install-once
// ticker advances it every second and flips a lapsed window to the kind's lapsed
// label. Read-only against the three seeded window fixtures in e2e/seed.rb.
//
// The live fixture is posted at seed time, so on a fast lane its chip reads
// "mm:ss" and TICKS; on a lane slower than the 10-minute window it reads the lapsed
// label — both are the contract, and the spec accepts either, asserting the tick
// only while the clock is still running. The hour-old fixture pins the lapsed label
// deterministically, so "lapsed" is never proven only by a slow run.
const CLOCK = /^\d{2}:\d{2}$/;

test("a waiting approval's card wears a ticking countdown, a lapsed one reads the lapsed label", async ({ page }) => {
  const res = await page.goto("/tasks");
  expect(res.ok()).toBe(true);

  const live = page.locator("#card-e2e-window-approval-demo [data-test='task-window-chip']");
  await expect(live).toBeVisible();
  await expect(live).toHaveAttribute("data-window-kind", "approval");
  const liveClock = live.locator("[data-test='task-window-clock']");
  await expect(liveClock).toHaveAttribute("data-mode", "window");

  const first = (await liveClock.textContent()).trim();
  if (CLOCK.test(first)) {
    await expect(live).toHaveAttribute("data-window-state", "open");
    // The ticker advances the painted value: within ~2s the text must differ and
    // still read as a clock.
    await expect.poll(async () => (await liveClock.textContent()).trim(), { timeout: 5_000 }).not.toBe(first);
    expect((await liveClock.textContent()).trim()).toMatch(CLOCK);
  } else {
    expect(first).toBe("unanswered, proceeding");
    await expect(live).toHaveAttribute("data-window-state", "lapsed");
  }

  // The hour-old request: lapsed for certain, dimmed, and its label names the default.
  const lapsed = page.locator("#card-e2e-window-lapsed-demo [data-test='task-window-chip']");
  await expect(lapsed).toBeVisible();
  await expect(lapsed).toHaveAttribute("data-window-kind", "approval");
  await expect(lapsed).toHaveAttribute("data-window-state", "lapsed");
  await expect(lapsed.locator("[data-test='task-window-clock']")).toHaveText("unanswered, proceeding");
  await expect(lapsed).not.toHaveAttribute("data-window-urgent", "true");

  // A card with nothing waiting on the operator wears no chip at all.
  const bystander = page.locator("#card-e2e-epic-chip-demo");
  await expect(bystander).toBeVisible();
  await expect(bystander.locator("[data-test='task-window-chip']")).toHaveCount(0);
});

test("an Escalated dependency block wears the escalation countdown", async ({ page }) => {
  const res = await page.goto("/tasks");
  expect(res.ok()).toBe(true);

  const card = page.locator("#card-e2e-window-escalation-demo");
  await expect(card).toBeVisible();
  const chip = card.locator("[data-test='task-window-chip']");
  await expect(chip).toHaveCount(1);
  await expect(chip).toHaveAttribute("data-window-kind", "escalation");
  await expect(chip).toHaveAttribute("data-window-state", "open");
  // Five minutes into a twenty-minute window: a clock in the 14:xx band, ticking.
  const clock = chip.locator("[data-test='task-window-clock']");
  const first = (await clock.textContent()).trim();
  expect(first).toMatch(/^1[34]:\d{2}$/);
  await expect.poll(async () => (await clock.textContent()).trim(), { timeout: 5_000 }).not.toBe(first);
  // The blocker's own summary still rides the card beneath it.
  await expect(card.locator("[data-test='blocker-summary']")).toHaveText("Escalated: chip colour default");
});
