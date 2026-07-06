const { test, expect } = require("@playwright/test");

// [e2e] The OPSD distillation pipeline (/alex/pipeline) — three columns, left→right:
// Activities (narrated AgentActivity rows) → Insights (Alex's banked grades) →
// Confirmations (McRitchie's mcr grades). A public read surface; the happy path here
// is the page rendering with all three columns and the nav's link out to the
// cross-session All Activities view.
test("alex pipeline renders the three distillation columns @qa-readonly", async ({ page }) => {
  const res = await page.goto("/alex/pipeline");
  expect(res.ok()).toBe(true);

  const root = page.locator("[data-test='alex-pipeline']");
  await expect(root).toBeVisible();

  // All three pipeline columns are present.
  await expect(page.locator("#col-actions")).toBeVisible();
  await expect(page.locator("#col-insights")).toBeVisible();
  await expect(page.locator("#col-confirmations")).toBeVisible();
  await expect(root).toContainText("Activities");
  await expect(root).toContainText("Insights");
  await expect(root).toContainText("Confirmations");

  // Column 1 lists the narrated activities (AgentActivity rows, each with a
  // category chip) — or, in a fresh env, its explicit "No activities yet."
  // placeholder. @qa-readonly runs against live QA and prod (bin/prod-smoke),
  // so assert the STRUCTURE either way — never seeded data.
  const activityRows = page.locator("[data-test='pl-activity']");
  const emptyState = page.locator("#col-actions .pl-empty");
  await expect(activityRows.first().or(emptyState)).toBeVisible();

  // The nav's required link out to the cross-session All Activities view.
  const allActivities = page.locator("[data-test='hb-nav-all-spans']");
  await expect(allActivities).toBeVisible();
  await expect(allActivities).toHaveAttribute("href", "/alex/heartbeat/activities");
});
