// [e2e] The /deployments DevOps card goes live (task devops-card-goes-live). Its two
// clocks are estimated on the server (Release::Flow#estimate), so a phase change used
// to leave an open page counting a stale estimate until reload. Now the card is a
// broadcast slot: Release#after_commit re-renders #devops-summary-card over the same
// "deployments" Turbo stream the board already subscribes to.
//
// e2e/seed.rb leaves one release assembling, short of QA green, so the QA clock is
// on the card. The spec turns QA green with the local-only dev trigger (a real
// Release#assemble!), and the open page — never reloaded — drops the QA clock; then
// it reopens the release (the same trigger, undo=1), the clock comes back, and the
// delegated ticker counts the REPLACED span down with nothing re-armed. The undo
// also leaves the seeded release assembling, as the specs after this one expect.
//
// NOT @qa-readonly: it writes the release e2e/seed.rb leaves in flight.
const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

const CARD = "#devops-summary-card";
const HERO = `${CARD} [data-test='devops-countdown'] [data-test='devops-eta'][data-devops-countdown]`;
const QA = `${CARD} [data-test='devops-qa-countdown']`;
const QA_ETA = `${QA} [data-test='devops-qa-eta'][data-devops-countdown]`;

test("QA green drops the DevOps card's QA clock live, and a reopen brings it back ticking", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  // A day behind the real clock, so every deadline the server stamps lies ahead.
  await page.clock.install({ time: Date.now() - 86_400_000 });
  await page.goto("/deployments");

  await expect(page.locator(HERO)).toBeVisible();
  await expect(page.locator(QA), "the seeded release is short of QA green").toBeVisible();
  // Subscribed before the write, so the broadcast cannot outrun the stream.
  await expect(page.locator("turbo-cable-stream-source[connected]").first()).toBeAttached();
  // A marker a reload would wipe: the card must change under the SAME document.
  await page.evaluate(() => { window.__devopsCardNoReload = true; });

  const green = await page.request.post("/dev/board/qa_green_release");
  expect(green.status()).toBe(204);
  await expect(page.locator(QA), "QA is green: the clock is gone").toHaveCount(0, { timeout: 10_000 });
  await expect(page.locator(HERO), "the landing clock stays").toBeVisible();

  const reopen = await page.request.post("/dev/board/qa_green_release", { form: { undo: "1" } });
  expect(reopen.status()).toBe(204);
  const qa = page.locator(QA_ETA);
  await expect(qa, "a reopen puts QA ahead again").toBeVisible({ timeout: 10_000 });
  expect(await page.evaluate(() => window.__devopsCardNoReload), "no reload happened").toBe(true);

  // The replaced span ticks off its own deadline: the module reads the page afresh
  // each second, so a swapped card needs nothing re-armed and no inline script.
  const qaDeadline = Date.parse(await qa.getAttribute("data-deadline"));
  expect(Number.isFinite(qaDeadline), "the new QA clock carries its deadline").toBe(true);
  await page.clock.pauseAt(qaDeadline - 90_000);
  await page.clock.runFor(1_000);
  await expect(qa).toHaveText("01:29");
  expect(pageErrors, report()).toEqual([]);
});
