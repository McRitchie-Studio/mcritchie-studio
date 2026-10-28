// [e2e] The /deployments DevOps card counts down to the in-flight release's landing
// (task devops-card-counts-down-to-ship; Release::Flow#estimate). e2e/seed.rb leaves
// one release assembling, so the hero is the clock: it carries the estimated landing
// as data-deadline, devops_countdown.js ticks it each second, and past the estimate it
// counts the overrun UP ("+12m over") in the warning ink instead of sitting at zero.
// The browser clock is driven from the hero's own deadline, so the seed's age and the
// history's medians do not matter.
//
// NOT @qa-readonly: it needs the release e2e/seed.rb leaves in flight.
const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

const HERO = "#devops-summary-card [data-test='devops-countdown'] [data-test='devops-eta'][data-devops-countdown]";

test("the DevOps hero counts down to the release's landing, then counts the overrun up in the warning ink", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  // An hour behind the real clock, so every deadline the server stamps is ahead of it.
  await page.clock.install({ time: Date.now() - 3_600_000 });
  await page.goto("/deployments");

  const hero = page.locator(HERO);
  const deadline = Date.parse(await hero.getAttribute("data-deadline"));
  expect(Number.isFinite(deadline), "the hero carries the estimated landing").toBe(true);
  await expect(page.locator("#devops-summary-card [data-test='devops-landing']")).toHaveText(/^(lands|due) ~\d{1,2}:\d{2} (AM|PM) MT$/);
  await expect(page.locator("#devops-summary-card [data-test='devops-mean']")).toBeVisible();

  await page.clock.pauseAt(deadline - 90_000);
  await page.clock.runFor(1_000);
  await expect(hero).toHaveText("01:29");
  await page.clock.runFor(29_000);
  await expect(hero).toHaveText("01:00");
  await expect(hero).toHaveCSS("font-variant-numeric", "tabular-nums");
  const counting = await hero.evaluate((el) => getComputedStyle(el).color);

  await page.clock.runFor(60_000 + 12 * 60_000);
  await expect(hero, "past the estimate it says how far over, never a zero").toHaveText("+12m over");
  await expect(hero).toHaveAttribute("data-eta-kind", "over");
  const late = await hero.evaluate((el) => getComputedStyle(el).color);
  expect(late, "the overrun wears the warning ink, not the heading ink").not.toEqual(counting);
  expect(pageErrors, report()).toEqual([]);
});
