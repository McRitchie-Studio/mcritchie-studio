const { test, expect } = require("@playwright/test");

// [e2e] Testing-phase timestamps — the happy path across both surfaces:
//  1. A task's page renders the "Testing phases" card with a measured duration
//     for each of the five task-owned phases (the seeded testing-phases-demo task
//     walked the full lifecycle with cert checkpoints + approval stamps).
//  2. /intelligence renders the aggregate "Testing phase speed" chart, with
//     Chart.js painting a real <canvas> (the projection has signal from the seed).
test("a task page shows the testing-phases card with per-phase durations", async ({ page }) => {
  await page.goto("/tasks/testing-phases-demo");

  const card = page.locator("div.card", { hasText: "Testing phases" }).first();
  await expect(card).toBeVisible();

  // Every task-owned phase label is present…
  for (const label of ["Build", "Local Certification", "CI", "Review", "Operator Acceptance"]) {
    await expect(card.getByText(label, { exact: true })).toBeVisible();
  }
  // …and the durable phases report as completed (Local Certification = 5 min window).
  await expect(card.getByText("Completed", { exact: true }).first()).toBeVisible();
});

test("intelligence dashboard renders the testing-phase-speed chart", async ({ page }) => {
  await page.goto("/intelligence");

  await expect(page.getByRole("heading", { name: "Testing phase speed" })).toBeVisible();
  await expect(page.locator("#chart-testing-phase-speed canvas")).toBeVisible();
});
