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

// [e2e] A2 happy path (seeded, local only — NOT @qa-readonly, since it asserts
// seeded rows): the "Test runs" band renders the release test-scope verdicts, a
// pass and a fail pill, the phase/tier/host chips derived from the scope
// registry, and a grade link; and a banked test-run grade surfaces as a Column-2
// insight with an ACTION Confirm button (confirm-of-action parity).
test("alex pipeline shows the gradeable test-runs band", async ({ page }) => {
  const res = await page.goto("/alex/pipeline");
  expect(res.ok()).toBe(true);

  const band = page.locator("[data-test='pl-test-runs']");
  await expect(band).toBeVisible();

  // The seeded passing verdict: scope key + pass pill + derived meta chips + grade link.
  const passRun = page.locator("[data-test='pl-test-run'][data-scope='ship_test_gate']");
  await expect(passRun).toBeVisible();
  await expect(passRun.locator("[data-test='pl-test-verdict']")).toHaveText("pass");
  await expect(passRun).toContainText("ship");
  await expect(passRun).toContainText("full");
  await expect(passRun).toContainText("local");
  await expect(passRun.locator("[data-test='pl-test-run-grade']")).toBeVisible();

  // The seeded failing verdict shows a fail pill.
  const failRun = page.locator("[data-test='pl-test-run'][data-scope='qa_up_smoke']");
  await expect(failRun.locator("[data-test='pl-test-verdict']")).toHaveText("fail");

  // The banked test-run grade is a Column-2 insight carrying an action Confirm button.
  await expect(page.locator("[data-test='pl-confirm-action-btn']").first()).toBeVisible();
});
