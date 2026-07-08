const { test, expect } = require("@playwright/test");

// [e2e] Testing gates — the branded gate verdicts (GateRun: G1 Cert, G2a
// Primary, G2b Light) on a task page. The seeded testing-phases-demo task
// carries a G1 that failed attempt 1 and passed attempt 2 (the retry count is
// load-bearing signal), a passed primary lane, and a light lane in flight.
test("a task page shows the testing-gates card with attempt-aware verdicts", async ({ page }) => {
  await page.goto("/tasks/testing-phases-demo");

  const card = page.locator("div.card", { hasText: "Testing gates" }).first();
  await expect(card).toBeVisible();

  for (const label of ["G1 Cert", "G2a Primary", "G2b Light"]) {
    await expect(card.getByText(label, { exact: true })).toBeVisible();
  }

  // G1 passed on attempt 2 — the chip carries the verdict AND the retry count…
  await expect(card.getByText("Passed", { exact: true }).first()).toBeVisible();
  await expect(card.getByText(/attempt 2/)).toBeVisible();
  // …the light lane is still in flight, ticking "so far".
  await expect(card.getByText("In flight", { exact: true })).toBeVisible();
  await expect(card.getByText(/so far/).first()).toBeVisible();

  // The G1 sops list expands to the executed SOPs with their verdicts.
  const g1Sops = card.locator("details", { hasText: "SOPs" }).first();
  await g1Sops.locator("summary").click();
  await expect(g1Sops.getByText("full-suite", { exact: true })).toBeVisible();
  await expect(g1Sops.getByText("dor-check", { exact: true })).toBeVisible();
});

// [e2e] Release gates on /deployments/all — the gate-backed G3/G4 columns
// (replacing Tested/Confirmed, whose bracket prepare used to co-opt so Tested
// started AFTER Assembled). The seeded Last Release carries a G3 that failed
// attempt 1 and passed attempt 2 (the ×2 retry badge is load-bearing) and a
// passed G4 with the prod-smoke seal as its closing SOP.
test("the all-deployments table renders gate-backed G3/G4 columns with the retry badge", async ({ page }) => {
  await page.goto("/deployments/all");

  const table = page.locator("table").first();
  await expect(table.locator("th", { hasText: "G3 Candidate" })).toBeVisible();
  await expect(table.locator("th", { hasText: "G4 Ship" })).toBeVisible();
  await expect(table.locator("th", { hasText: "Assembled" })).toBeVisible();
  // The co-opted stamp columns are gone from the header row.
  await expect(table.locator("th", { hasText: "Tested" })).toHaveCount(0);
  await expect(table.locator("th", { hasText: "Confirmed" })).toHaveCount(0);

  // G3 passed on attempt 2 → the ×2 retry badge renders in its cell.
  await expect(
    table.locator("[data-test='deployment-stage-attempts']", { hasText: "×2" }).first()
  ).toBeVisible();
});
