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
  // A day behind the real clock, so whatever deadline the server stamps — even a past
  // one, for a release already over — lies ahead of the installed time.
  await page.clock.install({ time: Date.now() - 86_400_000 });
  await page.goto("/deployments");

  const hero = page.locator(HERO);
  const deadline = Date.parse(await hero.getAttribute("data-deadline"));
  expect(Number.isFinite(deadline), "the hero carries the estimated landing").toBe(true);
  await expect(page.locator("#devops-summary-card [data-test='devops-landing']")).toHaveText(/^(lands|due) ~\d{1,2}:\d{2} (AM|PM) MT$/);
  await expect(page.locator("#devops-summary-card [data-test='devops-mean']")).toBeVisible();

  // The QA-green clock on the right: the seeded release has not reached QA green, so
  // it is there, due no later than the landing, and ticked by the same module.
  const qa = page.locator("#devops-summary-card [data-test='devops-qa-countdown'] [data-test='devops-qa-eta'][data-devops-countdown]");
  const qaDeadline = Date.parse(await qa.getAttribute("data-deadline"));
  // The seed's history holds Hold and Ship for minutes, so QA green is well before the
  // landing — which also keeps the two clock jumps below in order.
  expect(deadline - qaDeadline, "QA green comes minutes before the landing").toBeGreaterThan(60_000);
  await page.clock.pauseAt(qaDeadline - 30_000);
  await page.clock.runFor(1_000);
  await expect(qa).toHaveText("00:29");

  await page.clock.pauseAt(deadline - 90_000);
  await page.clock.runFor(1_000);
  await expect(hero).toHaveText("01:29");
  await page.clock.runFor(29_000);
  await expect(hero).toHaveText("01:00");
  await expect(hero).toHaveCSS("font-variant-numeric", "tabular-nums");
  const counting = await hero.evaluate((el) => getComputedStyle(el).color);

  // fastForward, not runFor: runFor fires every one-second interval on the board for
  // thirteen minutes of ticks and outruns the test clock on CI; fastForward jumps,
  // then one real tick repaints.
  await page.clock.fastForward(60_000 + 12 * 60_000);
  await page.clock.runFor(1_000);
  await expect(hero, "past the estimate it says how far over, never a zero").toHaveText("+12m over");
  await expect(hero).toHaveAttribute("data-eta-kind", "over");
  const late = await hero.evaluate((el) => getComputedStyle(el).color);
  expect(late, "the overrun wears the warning ink, not the heading ink").not.toEqual(counting);
  expect(pageErrors, report()).toEqual([]);
});
