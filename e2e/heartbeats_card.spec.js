const { test, expect } = require("@playwright/test");

// The /deployments Heartbeats card after the souls+heartbeats reslot (2026-07-22):
// FOUR soul launchers — Carl (review), Avi (assemble/QA), Steffon (ship/archive),
// Alex — in a 4-up grid. This is the browser-level check that the reslotted acts
// render under the RIGHT souls end to end (the component/integration specs cover the
// render; this proves it survives a real page load on the live board).
test("the deployments Heartbeats card renders four soul launchers with the reslotted acts", async ({ page }) => {
  await page.goto("/deployments");

  const card = page.locator("[data-test='heartbeats-card']");
  await expect(card).toBeVisible();

  // Four souls now — Carl's column was added.
  await expect(card.locator("[data-test='heartbeat-launcher']")).toHaveCount(4);
  const grid = card.locator("div.grid.sm\\:grid-cols-4");
  await expect(grid).toHaveCount(1);

  // Carl owns review: his column carries the pr-review + pr-review-slow chips.
  const carl = card.locator("[data-test='heartbeat-launcher'][data-agent='carl']");
  await expect(carl).toHaveCount(1);
  await expect(carl.locator("button[data-clip='Carl Heartbeat']")).toHaveCount(1);
  await expect(carl.locator("button[data-clip='pr-review']")).toHaveCount(1);
  await expect(carl.locator("button[data-clip='pr-review-slow']")).toHaveCount(1);

  // Avi owns qa-release (assemble + QA).
  const avi = card.locator("[data-test='heartbeat-launcher'][data-agent='avi']");
  await expect(avi.locator("button[data-clip='qa-release']")).toHaveCount(1);

  // Steffon owns production-deploy + archive-shipped (ship + archive).
  const steffon = card.locator("[data-test='heartbeat-launcher'][data-agent='steffon']");
  await expect(steffon.locator("button[data-clip='production-deploy']")).toHaveCount(1);
  await expect(steffon.locator("button[data-clip='archive-shipped']")).toHaveCount(1);
});
