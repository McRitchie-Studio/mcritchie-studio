const { test, expect } = require("@playwright/test");

// [e2e] Testing-phase timestamps — the happy path across both surfaces:
//  1. A task's page renders the "Testing phases" card with a measured duration
//     for each of the four task-owned phases (the seeded testing-phases-demo task
//     walked the full lifecycle with cert checkpoints, CI evidence + a review
//     gate run; Operator Acceptance left the projection in v2).
//  2. /intelligence renders the aggregate "Testing phase speed" chart, with
//     Chart.js painting a real <canvas> (the projection has signal from the seed).
test("a task page shows the testing-phases card with per-phase durations", async ({ page }) => {
  await page.goto("/tasks/testing-phases-demo");

  const card = page.locator("div.card", { hasText: "Testing phases" }).first();
  await expect(card).toBeVisible();

  // Every task-owned phase label is present…
  for (const label of ["Build", "Local Certification", "CI", "Review"]) {
    await expect(card.getByText(label, { exact: true })).toBeVisible();
  }
  // …the v2 projection has no Operator Acceptance tile…
  await expect(card.getByText("Operator Acceptance", { exact: true })).toHaveCount(0);
  // …and the durable phases report as completed (Local Certification = 5 min window).
  await expect(card.getByText("Completed", { exact: true }).first()).toBeVisible();
});

test("intelligence dashboard renders the testing-phase-speed chart", async ({ page }) => {
  await page.goto("/intelligence");

  await expect(page.getByRole("heading", { name: "Testing phase speed" })).toBeVisible();
  await expect(page.locator("#chart-testing-phase-speed canvas")).toBeVisible();
});

// [e2e] /tasks/recent — the public recency scanning surface. The phase strip is a
// fixed grid keyed by PHASE_KEYS, so v2 (acceptance dropped) must render exactly
// four cells — Build · Cert · CI · Review — with NO "Accept" track. This is the
// public render the reviewers flagged as v1-stale (no e2e covered it before).
test("the recent-tasks phase strip shows four v2 cells and no Accept track", async ({ page }) => {
  await page.goto("/tasks/recent");

  const row = page.locator('[data-test="recent-task-row"][data-task-slug="testing-phases-demo"]');
  await expect(row).toBeVisible();

  const strip = row.locator('[data-test="recent-task-phases"]');
  for (const label of ["Build", "Cert", "CI", "Review"]) {
    await expect(strip.getByText(label, { exact: true })).toBeVisible();
  }
  // The dropped Operator Acceptance phase leaves no "Accept" cell — the whole
  // page must not ship the vestigial fifth track.
  await expect(strip.getByText("Accept", { exact: true })).toHaveCount(0);
  await expect(page.getByText("Accept", { exact: true })).toHaveCount(0);
});
