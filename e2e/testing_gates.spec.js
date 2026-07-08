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
