const { test, expect } = require("@playwright/test");

// [e2e] devops-namespace (Alex McRitchie, 2026-11-07): the board and its insight pages
// live under /devops, and their crumb trail starts at DevOps. The old addresses answer
// 301 to the new ones, so a printed /tasks/:slug link lands on the task's new page. The
// seeded task timeline-demo (e2e/seed.rb) is the task page; the spec only reads it.

const SLUG = "timeline-demo";

test("the board home loads at /devops", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const res = await page.goto("/devops");
  expect(res.status()).toBe(200);
  await expect(page).toHaveURL(/\/devops$/);
  await expect(page.locator("h1.page-header-title")).toHaveText("Deployments");
});

test("a task page loads under /devops with a trail that starts at DevOps", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const res = await page.goto(`/devops/tasks/${SLUG}`);
  expect(res.status()).toBe(200);
  const first = page.locator(".page-header-crumbs a.page-header-crumb").first();
  await expect(first).toHaveText("DevOps");
  await expect(first).toHaveAttribute("href", "/devops");
});

test("triage loads under /devops with a trail that starts at DevOps", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const res = await page.goto("/devops/triage");
  expect(res.status()).toBe(200);
  await expect(page.locator(".page-header-crumbs a.page-header-crumb")).toHaveText(["DevOps"]);
});

test("an old /tasks/:slug link lands on the task's /devops page, query kept", async ({ page, request }) => {
  const hop = await request.get(`/tasks/${SLUG}?from=discord`, { maxRedirects: 0 });
  expect(hop.status()).toBe(301);
  expect(new URL(hop.headers()["location"]).pathname).toBe(`/devops/tasks/${SLUG}`);

  await page.goto(`/tasks/${SLUG}?from=discord`);
  await expect(page).toHaveURL(new RegExp(`/devops/tasks/${SLUG}\\?from=discord$`));
  await expect(page.locator("[data-test='task-slug']").first()).toHaveText(SLUG);
});
