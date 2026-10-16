// [e2e] An app owner reads their CTO's usage (docs/agents/system/agent-usage.md).
// owner@turf.test owns Turf Monster (e2e/seed.rb seeds one answered client
// message this month on the Builder tier). The app page shows the usage card:
// the meter (unlimited, since the shipped allowances are blank), this month's
// totals and today's; the CTO's settings page shows the same meter; the admin
// levers are not offered to an owner. At phone width nothing runs off the side.
//
// NOT @qa-readonly: it reads rows only e2e/seed.rb creates. Nothing here talks to Discord.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

test("an owner sees Turf's usage meter and totals on the app and CTO pages", async ({ page }) => {
  await loginWithMagicLink(page, "owner@turf.test");

  await page.goto("/applications/turf-monster");
  const card = page.locator("[data-test='application-usage-card']");
  await expect(card.getByRole("heading", { name: "Agent usage" })).toBeVisible();
  await expect(card.locator("[data-test='usage-meter']")).toHaveAttribute("data-state", "unlimited");
  await expect(card.locator("[data-test='usage-meter-line']")).toContainText("19,500 metered tokens this month");
  await expect(card).toContainText("Builder tier");
  await expect(card.locator("[data-test='application-usage-month']")).toContainText("1 answer, 19,500 tokens");
  await expect(card.locator("[data-test='application-usage-admin']")).toHaveCount(0);

  await page.setViewportSize({ width: 390, height: 844 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "nothing runs off the side at 390px").toBeLessThanOrEqual(0);

  await page.goto("/agents/turf-monster/settings");
  await expect(page.locator("[data-test='agent-usage-card'] [data-test='usage-meter']")).toHaveAttribute("data-state", "unlimited");
});
