const { test, expect } = require("@playwright/test");

// The BUILDING card's local-check indicator (feature: show-local-test-progress) —
// the CI meter's counterpart for the stretch before a PR exists.
//
// Why this needs a real browser rather than only the rendered-partial tier: the two
// states differ by an ANIMATION and a LIVE CLOCK, and both are invisible to
// assert_select. A spinner that does not actually spin, or a "running" clock frozen
// at its server-rendered value, would pass every request test while telling the
// operator nothing — the indicator would look alive on a card that is not.
//
// Seeded by e2e/seed.rb: e2e-local-check-running (a beating cert) and
// e2e-local-check-stalled (last beat long past).

test.use({ viewport: { width: 1600, height: 1000 } });

test("a building card names the lane its local cert is running, with a live clock", async ({ page }) => {
  await page.goto("/tasks");

  const card = page.locator("#card-e2e-local-check-running");
  await expect(card).toBeVisible();

  const slot = card.locator("[data-test='task-local-check']");
  await expect(slot).toHaveAttribute("data-local-check-state", "running");
  await expect(slot.locator("[data-test='task-local-check-label']")).toHaveText(/Running mapped tests/);

  // The spinner is genuinely animating — the thing that says "still working".
  const spinner = slot.locator("[data-test='task-local-check-spinner']");
  await expect(spinner).toBeVisible();
  await expect(spinner).toHaveClass(/animate-spin/);

  // The command rides along so the operator can see what is executing.
  await expect(slot).toHaveAttribute("title", /bin\/rails test/);

  // THE CLOCK MUST ACTUALLY TICK. A server-rendered number that never moves is the
  // exact failure this indicator is supposed to rule out.
  //
  // Driven by Playwright's CLOCK rather than by waiting on real time, because the
  // shared ticker renders data-mode="short" as a SINGLE unit ("47s", then "3m") —
  // past a minute the text only changes once per minute, so any real-time poll
  // short enough to keep the suite fast could never observe a change, and a longer
  // one would just be a slow way to be flaky. Fast-forwarding two minutes proves
  // the same thing in milliseconds, and proves it every run.
  const clock = slot.locator("[data-test='task-local-check-clock']");
  await expect(clock).toHaveAttribute("data-local-check-clock", "running");
  await expect(clock).toHaveAttribute("data-release-ticker", "");
  const first = await clock.textContent();
  await page.clock.install();
  await page.clock.fastForward("02:00");
  await expect.poll(async () => await clock.textContent(), { timeout: 5000 }).not.toBe(first);
});

test("a killed runner shows STALLED with a frozen clock, never an endless spinner", async ({ page }) => {
  await page.goto("/tasks");

  const card = page.locator("#card-e2e-local-check-stalled");
  await expect(card).toBeVisible();

  const slot = card.locator("[data-test='task-local-check']");
  await expect(slot).toHaveAttribute("data-local-check-state", "stalled");
  await expect(slot.locator("[data-test='task-local-check-label']")).toHaveText(/stalled/i);

  // No spinner: a stalled check must stop claiming progress.
  await expect(slot.locator("[data-test='task-local-check-spinner']")).toHaveCount(0);
  await expect(slot.locator("[data-test='task-local-check-stalled-icon']")).toBeVisible();

  // And the clock is FROZEN — it must not keep counting up on a dead process. Same
  // clock fast-forward as the running case, so this is a real control rather than a
  // pause too short for the minute-granularity to have moved anyway: two minutes
  // pass and the number does NOT budge.
  const clock = slot.locator("[data-test='task-local-check-clock']");
  await expect(clock).toHaveAttribute("data-local-check-clock", "stalled");
  await expect(clock).not.toHaveAttribute("data-release-ticker", /.*/);
  const first = await clock.textContent();
  await page.clock.install();
  await page.clock.fastForward("02:00");
  await page.waitForTimeout(500);
  await expect(clock).toHaveText(first);
});
