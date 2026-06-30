const { test, expect } = require("@playwright/test");

// The Alex avenue (/alex/heartbeat) renders the atomic trajectory table from the
// seeded AtomicAction trajectory — rows oldest -> newest, grouped by stage.
test("alex heartbeat renders the seeded atomic trajectory table", async ({ page }) => {
  await page.goto("/alex/heartbeat");

  const table = page.locator("[data-test='heartbeat-table']");
  await expect(table).toBeVisible();

  // The seeded demo trajectory has several actions, all visible by default.
  const rows = page.locator("tr[data-test='heartbeat-row']");
  await expect(rows.first()).toBeVisible();
  expect(await rows.count()).toBeGreaterThanOrEqual(5);

  // Grouped by stage: the null-stage Session group plus a Building group.
  await expect(page.locator("[data-test='heartbeat-group'][data-stage='session']")).toBeVisible();
  await expect(page.locator("[data-test='heartbeat-group'][data-stage='building']")).toBeVisible();

  // Dense ported columns: short model label + an outcome badge.
  await expect(table).toContainText("opus-4-8");
  await expect(table.locator("span.hb-outcome", { hasText: "ok" }).first()).toBeVisible();
});

// Collapsing a stage group (Alpine) hides its action rows.
test("a stage group collapses its rows on click", async ({ page }) => {
  await page.goto("/alex/heartbeat");

  const group = page.locator("[data-test='heartbeat-group'][data-stage='building']");
  const firstRow = group.locator("tr[data-test='heartbeat-row']").first();
  await expect(firstRow).toBeVisible();

  await group.locator("tr.hb-grouphead").click();
  await expect(firstRow).toBeHidden();
});

// The launcher's Alex avenue links straight to the heartbeat trajectory.
test("the session launcher Alex avenue links to the heartbeat trajectory", async ({ page }) => {
  await page.goto("/launcher");

  const alex = page.locator("a[data-avenue='alex']");
  await expect(alex).toHaveAttribute("href", "/alex/heartbeat");

  await alex.click();
  await expect(page.locator("[data-test='heartbeat-table']")).toBeVisible();
});
