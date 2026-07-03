const { test, expect } = require("@playwright/test");

// [e2e] The OPSD distillation pipeline (/alex/pipeline) — three columns, left→right:
// Actions (the seeded spans) → Insights (Alex's banked grades) → Confirmations
// (McRitchie's mcr grades). A public read surface; the happy path here is the page
// rendering with all three columns and the link out to the full All Spans view.
test("alex pipeline renders the three distillation columns @qa-readonly", async ({ page }) => {
  const res = await page.goto("/alex/pipeline");
  expect(res.ok()).toBe(true);

  const root = page.locator("[data-test='alex-pipeline']");
  await expect(root).toBeVisible();

  // All three pipeline columns are present.
  await expect(page.locator("#col-actions")).toBeVisible();
  await expect(page.locator("#col-insights")).toBeVisible();
  await expect(page.locator("#col-confirmations")).toBeVisible();
  await expect(root).toContainText("Actions");
  await expect(root).toContainText("Insights");
  await expect(root).toContainText("Confirmations");

  // Column 1 lists the seeded spans (each a narrated AtomicEvent with a type badge).
  const spans = page.locator("[data-test='pl-span']");
  expect(await spans.count()).toBeGreaterThanOrEqual(1);

  // The required link out to the full All Spans view.
  await expect(page.locator("a[href='/alex/heartbeat/spans']").first()).toBeVisible();
});
