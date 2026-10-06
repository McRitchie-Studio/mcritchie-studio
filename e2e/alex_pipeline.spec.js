const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

// [e2e] The pipeline sits behind the admin wall (app/controllers/concerns/admin_wall.rb).
// @qa-readonly: bin/prod-smoke runs this against QA and PRODUCTION as a visitor, so it
// asserts the wall — a signed-out visitor is sent to sign-in and never sees the page.
test.describe("xan pipeline admin wall", () => {
  test.use({ storageState: VISITOR });

  test("xan pipeline sends a visitor to sign-in @qa-readonly", async ({ page, request }) => {
    const res = await request.get("/xan/pipeline", { maxRedirects: 0 });
    expect(res.status()).toBe(302);
    expect(new URL(res.headers()["location"], "http://host").pathname).toBe("/login");

    await page.goto("/xan/pipeline");
    expect(new URL(page.url()).pathname).toMatch(/^\/(login|signin)$/);
    await expect(page.locator('input[name="email"]')).toBeVisible();
    await expect(page.locator("[data-test='xan-pipeline']")).toHaveCount(0);
  });
});

// [e2e] The OPSD distillation pipeline (/xan/pipeline) — three columns, left→right:
// Activities (narrated AgentActivity rows) → Insights (Xan's banked grades) →
// Confirmations (McRitchie's mcr grades). An admin page; the happy path here is the
// page rendering, as the seeded admin, with all three columns and the nav's link out
// to the cross-session All Activities view. Local lane only (no admin session in
// prod-smoke), so NOT @qa-readonly.
test("xan pipeline renders the three distillation columns", async ({ page }) => {
  const res = await page.goto("/xan/pipeline");
  expect(res.ok()).toBe(true);

  const root = page.locator("[data-test='xan-pipeline']");
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
  // placeholder. Assert the STRUCTURE either way — never seeded data.
  const activityRows = page.locator("[data-test='pl-activity']");
  const emptyState = page.locator("#col-actions .pl-empty");
  await expect(activityRows.first().or(emptyState)).toBeVisible();

  // The nav's required link out to the cross-session All Activities view.
  const allActivities = page.locator("[data-test='hb-nav-all-spans']");
  await expect(allActivities).toBeVisible();
  await expect(allActivities).toHaveAttribute("href", "/xan/heartbeat/activities");
});

// [e2e] A2 happy path (seeded, local only — NOT @qa-readonly, since it asserts
// seeded rows): the "Test runs" band renders the release test-scope verdicts, a
// pass and a fail pill, the phase/tier/host chips derived from the scope
// registry, and a grade link; and a banked test-run grade surfaces as a Column-2
// insight with an ACTION Confirm button (confirm-of-action parity).
test("xan pipeline shows the gradeable test-runs band", async ({ page }) => {
  const res = await page.goto("/xan/pipeline");
  expect(res.ok()).toBe(true);

  const band = page.locator("[data-test='pl-test-runs']");
  await expect(band).toBeVisible();

  // The seeded passing verdict: scope key + pass pill + derived meta chips + grade link.
  const passRun = page.locator("[data-test='pl-test-run'][data-scope='ship_test_gate']");
  await expect(passRun).toBeVisible();
  await expect(passRun.locator("[data-test='pl-test-verdict']")).toHaveText("pass");
  // ship_test_gate is a READ of CI's verdict for the frozen tree (host: ci) — CI ran
  // the full suite; this box only read the conclusion.
  await expect(passRun).toContainText("ship");
  await expect(passRun).toContainText("full");
  await expect(passRun).toContainText("ci");
  await expect(passRun.locator("[data-test='pl-test-run-grade']")).toBeVisible();

  // The seeded failing verdict shows a fail pill.
  const failRun = page.locator("[data-test='pl-test-run'][data-scope='qa_up_smoke']");
  await expect(failRun.locator("[data-test='pl-test-verdict']")).toHaveText("fail");

  // The banked test-run grade is a Column-2 insight carrying an action Confirm button.
  await expect(page.locator("[data-test='pl-confirm-action-btn']").first()).toBeVisible();
});
