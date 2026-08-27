const { test, expect } = require("@playwright/test");

// The /deployments WORKFLOWS card (renamed from Heartbeats — every row is a flow the
// operator launches, not a liveness signal): FIVE soul launchers — Carl (review),
// Avi (assemble/QA), Steffon (ship + infra sweep), Alex, and Turf Monster (live
// scores). This is the browser-level check that the acts render under the RIGHT souls
// end to end; the component/integration specs cover the render, this proves it
// survives a real page load on the live board.
test("the deployments Workflows card renders five soul launchers with their acts", async ({ page }) => {
  await page.goto("/deployments");

  const card = page.locator("[data-test='heartbeats-card']");
  await expect(card).toBeVisible();

  // The card is named for the flows it launches.
  await expect(card.locator("h3")).toHaveText("Workflows");

  // Five souls now — Turf Monster's column was added.
  await expect(card.locator("[data-test='heartbeat-launcher']")).toHaveCount(5);
  // The column count tracks the CARD's width, not the viewport's: the dashboard
  // halves this card at xl, so the ladder goes 5 at lg, 3 at xl, 5 again at 2xl.
  // Assert the lg rung — the one that says "five across when there is room".
  await expect(card.locator("div.grid.lg\\:grid-cols-5")).toHaveCount(1);

  // Carl owns review: his column carries the pr-review + pr-review-slow chips.
  const carl = card.locator("[data-test='heartbeat-launcher'][data-agent='carl']");
  await expect(carl).toHaveCount(1);
  await expect(carl.locator("button[data-clip='Carl Heartbeat']")).toHaveCount(1);
  await expect(carl.locator("button[data-clip='pr-review']")).toHaveCount(1);
  await expect(carl.locator("button[data-clip='pr-review-slow']")).toHaveCount(1);

  // Avi owns qa-release (assemble + QA).
  const avi = card.locator("[data-test='heartbeat-launcher'][data-agent='avi']");
  await expect(avi.locator("button[data-clip='qa-release']")).toHaveCount(1);

  // Steffon owns production-deploy + clean-infra. archive-shipped is NOT a chip any
  // more: production-deploy runs it as its final step, so the cleaning rides every
  // release instead of waiting to be remembered. It stays invocable by name.
  const steffon = card.locator("[data-test='heartbeat-launcher'][data-agent='steffon']");
  await expect(steffon.locator("button[data-clip='production-deploy']")).toHaveCount(1);
  await expect(steffon.locator("button[data-clip='clean-infra']")).toHaveCount(1);
  await expect(card.locator("button[data-clip='archive-shipped']")).toHaveCount(0);

  // Turf Monster is the fifth soul, owning the live score watch.
  const turf = card.locator("[data-test='heartbeat-launcher'][data-agent='turf-monster']");
  await expect(turf).toHaveCount(1);
  await expect(turf.locator("button[data-clip='Turf Monster Heartbeat']")).toHaveCount(1);
  await expect(turf.locator("button[data-clip='live-score-watch']")).toHaveCount(1);
});
