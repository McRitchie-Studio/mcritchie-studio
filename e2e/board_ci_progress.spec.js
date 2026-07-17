const { test, expect } = require("@playwright/test");

// The board's CI progress meters (feature: visual-ci-progress-bars, v1.2:
// clickable-symbolic-ci-checks). Data is seeded by e2e/seed.rb: a submitted "E2E CI
// progress demo" task with a live PR CI run, and a CI run on the active
// release-branch tip. The check counts come from the CI_PROGRESS_FIXTURES webServer
// env, so the render never touches GitHub. All the demo suites have 8 checks — under
// the 12-check threshold — so each renders the SYMBOLIC row (one glyph per check).

// A wide viewport: the six-lane Deployments board collapses the upstream lanes
// (submitted among them) below 1400px unless "All Stages" is on, so the demo
// card's column must be given room to render.
test.use({ viewport: { width: 1600, height: 1000 } });

test("a submitted task card shows its CI checks as symbols, linked to the PR", async ({ page }) => {
  await page.goto("/deployments");

  const card = page.locator("#card-e2e-ci-progress-demo");
  await expect(card).toBeVisible();

  // A small suite (6 passed + 2 running) renders one icon per check — plus the bar,
  // together — inside a distinct outlined card, not the "X / Y" fraction text.
  await expect(card.locator("[data-test='task-ci-progress-symbols']")).toBeVisible();
  await expect(card.locator("[data-test='ci-check-symbol']")).toHaveCount(8);
  await expect(card.locator("[data-test='ci-check-symbol'] svg").first()).toBeVisible();
  await expect(card.locator("[data-test='task-card-ci-progress'] [role='progressbar']")).toBeVisible();
  await expect(card.locator("[data-test='task-ci-progress-fraction']")).toHaveCount(0);

  // The whole outlined card is a link opening the task's PR in a new tab.
  const link = card.locator("a.ci-progress-card[data-test='task-card-ci-progress']");
  await expect(link).toHaveAttribute("href", /\/pull\/900$/);
  await expect(link).toHaveAttribute("target", "_blank");
  await expect(link).toHaveAttribute("rel", "noopener");
});

test("the Next Release card shows the G3 candidate CI as symbols", async ({ page }) => {
  await page.goto("/deployments");

  const meter = page.locator("#current-release [data-test='release-ci-progress-symbols']");
  await expect(meter).toBeVisible();
  await expect(page.locator("#current-release [data-test='ci-check-symbol']")).toHaveCount(8);
});

// v1.1 + v1.2 — the live path: this card's meter is folded from ingested CiCheckJob
// rows (the workflow_job webhook), NOT the fixture seam. Its SHA has no
// CI_PROGRESS_FIXTURES entry, so a rendered meter proves Ci::ProgressReader prefers
// the live rows. The stable #ci-progress slot is what a real workflow_job push
// morph-replaces with no reload.
test("a submitted task card renders its CI symbols from LIVE workflow_job rows", async ({ page }) => {
  await page.goto("/deployments");

  const card = page.locator("#card-e2e-live-ci-progress-demo");
  await expect(card).toBeVisible();

  await expect(card.locator("[data-test='task-ci-progress-symbols']")).toBeVisible();
  await expect(card.locator("[data-test='ci-check-symbol']")).toHaveCount(8);
  await expect(card.locator("#ci-progress-e2e-live-ci-progress-demo")).toBeVisible();
});
