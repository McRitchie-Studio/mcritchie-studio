const { test, expect } = require("@playwright/test");

// [e2e] /intelligence is a public-read dashboard (no login). It loads the
// TaskIntelligence aggregations and renders them as Chartkick/Chart.js charts.
// The seeded shipped+sized demo tasks give every chart signal, so we assert the
// page shell, the section headings, that Chart.js actually painted <canvas>
// elements (the importmap chart stack wired up), and that the leaderboard
// surfaces a seeded task.
test("intelligence dashboard renders headings, chart canvases, and leaderboards", async ({ page }) => {
  await page.goto("/intelligence");

  // Page shell
  await expect(page.getByRole("heading", { name: "Task Intelligence", level: 1 })).toBeVisible();
  await expect(page.locator("[data-test='intelligence-dashboard']")).toBeVisible();
  await expect(page.locator("[data-test='summary-tiles']")).toBeVisible();

  // Section headings across the dashboard
  for (const name of ["Stage speed", "Cycle time by task", "Tokens per task", "Cost per task", "Estimate vs actual", "Model mix"]) {
    await expect(page.getByRole("heading", { name })).toBeVisible();
  }

  // Chart.js painted real canvases inside the chart containers (proves chartkick
  // + chart.js loaded over importmap and the chartkick:load handoff fired).
  await expect(page.locator("#chart-stage-speed canvas")).toBeVisible();
  await expect(page.locator("#chart-cost-task canvas")).toBeVisible();
  expect(await page.locator("canvas").count()).toBeGreaterThanOrEqual(5);

  // Leaderboard surfaces a seeded shipped task with its spend
  const priciest = page.locator("[data-test='priciest-tasks']");
  await expect(priciest).toContainText("Intelligence demo shipped");
  await expect(priciest.locator("table tbody tr").first()).toBeVisible();
});
