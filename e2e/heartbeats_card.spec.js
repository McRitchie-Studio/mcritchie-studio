const { test, expect } = require("@playwright/test");
const { openDeploySidebar } = require("./helpers");

// The /deployments WORKFLOWS surface: FIVE soul launchers — Turf Monster (live scores),
// Carl (review), Avi (assemble/QA), Steffon (ship + infra sweep) and Alex. Since the
// summary row (2026-09-18) they are drawn twice: ONE soul at a time on the Workflows
// summary card's carousel, and every soul with every command in the Workflows sidebar.
// This is the browser-level check that the acts render under the RIGHT souls end to end,
// in the sidebar the operator actually opens.
test("the Workflows sidebar lists five soul launchers with their acts", async ({ page }) => {
  await page.goto("/deployments");

  // The carousel starts on Turf Monster, the operator's spec.
  const summary = page.locator("#agents-summary-card");
  await expect(summary).toHaveAttribute("data-active-agent", "turf-monster");
  await expect(summary.locator("[data-test='soul-slide'][data-place='active']")).toHaveAttribute("data-agent", "turf-monster");

  await openDeploySidebar(page, "agents");
  const card = page.locator("#deploy-sidebar-agents [data-test='heartbeats-card']");
  await expect(card).toBeVisible();

  await expect(card.locator("[data-test='heartbeat-launcher']")).toHaveCount(5);

  // Carl owns review: his row carries the pr-review + pr-review-slow chips.
  const carl = card.locator("[data-test='heartbeat-launcher'][data-agent='carl']");
  await expect(carl).toHaveCount(1);
  await expect(carl.locator("button[data-clip='Carl Heartbeat']")).toBeVisible();
  await expect(carl.locator("button[data-clip='pr-review']")).toBeVisible();
  await expect(carl.locator("button[data-clip='pr-review-slow']")).toBeVisible();

  // Avi owns qa-release (assemble + QA).
  const avi = card.locator("[data-test='heartbeat-launcher'][data-agent='avi']");
  await expect(avi.locator("button[data-clip='qa-release']")).toBeVisible();

  // Steffon owns production-deploy + clean-infra. archive-shipped is NOT a chip:
  // production-deploy runs it as its final step, so the cleaning rides every release
  // instead of waiting to be remembered. It stays invocable by name.
  const steffon = card.locator("[data-test='heartbeat-launcher'][data-agent='steffon']");
  await expect(steffon.locator("button[data-clip='production-deploy']")).toBeVisible();
  await expect(steffon.locator("button[data-clip='clean-infra']")).toBeVisible();
  await expect(page.locator("button[data-clip='archive-shipped']")).toHaveCount(0);

  // Alex's third act is visible here — nothing in the sidebar hides behind a toggle.
  const alex = card.locator("[data-test='heartbeat-launcher'][data-agent='alex']");
  await expect(alex.locator("button[data-clip='full-cycle']")).toBeVisible();

  // Turf Monster owns the live score watch.
  const turf = card.locator("[data-test='heartbeat-launcher'][data-agent='turf-monster']");
  await expect(turf.locator("button[data-clip='Turf Monster Heartbeat']")).toBeVisible();
  await expect(turf.locator("button[data-clip='live-score-watch']")).toBeVisible();
});
