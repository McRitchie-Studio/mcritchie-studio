const { test, expect } = require("@playwright/test");

// The board's CI progress bars (feature: visual-ci-progress-bars). Data is seeded
// by e2e/seed.rb: a submitted "E2E CI progress demo" task with a live PR CI run,
// and a CI run on the active release-branch tip. The check counts come from the
// CI_PROGRESS_FIXTURES webServer env, so the render never touches GitHub.

// A wide viewport: the six-lane Deployments board collapses the upstream lanes
// (submitted among them) below 1400px unless "All Stages" is on, so the demo
// card's column must be given room to render.
test.use({ viewport: { width: 1600, height: 1000 } });

test("a submitted task card shows its CI progress meter", async ({ page }) => {
  await page.goto("/deployments");

  const card = page.locator("#card-e2e-ci-progress-demo");
  await expect(card).toBeVisible();

  await expect(card.locator("[data-test='task-card-ci-progress']")).toBeVisible();
  await expect(card.locator("[data-test='task-ci-progress-fraction']")).toContainText("6 / 8");
  await expect(card.locator("[data-test='task-ci-progress-fill']")).toBeVisible();
});

test("the Next Release card shows the G3 candidate CI meter", async ({ page }) => {
  await page.goto("/deployments");

  await expect(page.locator("#current-release [data-test='release-ci-progress']")).toBeVisible();
  await expect(page.locator("#current-release [data-test='release-ci-progress-fraction']")).toContainText("8 / 8");
});

// v1.1 — the live path: this card's bar is folded from ingested CiCheckJob rows
// (the workflow_job webhook), NOT the fixture seam. Its SHA has no CI_PROGRESS_FIXTURES
// entry, so a rendered bar proves Ci::ProgressReader prefers the live rows. The stable
// #ci-progress slot is what a real workflow_job push morph-replaces with no reload.
test("a submitted task card renders its CI meter from LIVE workflow_job rows", async ({ page }) => {
  await page.goto("/deployments");

  const card = page.locator("#card-e2e-live-ci-progress-demo");
  await expect(card).toBeVisible();

  await expect(card.locator("[data-test='task-card-ci-progress']")).toBeVisible();
  await expect(card.locator("[data-test='task-ci-progress-fraction']")).toContainText("5 / 8");
  await expect(card.locator("#ci-progress-e2e-live-ci-progress-demo")).toBeVisible();
});
