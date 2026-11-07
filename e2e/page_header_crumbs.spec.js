const { test, expect } = require("@playwright/test");

// [e2e] The crumb header on the hub's admin pages (studio-engine studio/_page_header,
// crumbs from config/navigation.yml's parents) and the back move it plays: a crumb up
// the trail, and browser Back, slide the hub's :left move the other way.

// The style each Turbo visit plays, read as the engine sets it at turbo:before-render.
async function recordMoves(page) {
  await page.addInitScript(() => {
    window.__moves = [];
    document.addEventListener("turbo:before-render", () => {
      window.__moves.push(document.documentElement.dataset.pageTransition || "none");
    });
  });
}

async function visitBy(page, action) {
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await action();
  await load;
}

test("/deployments wears the crumb header: trail, h2-size title, actions right, links under it", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/deployments");
  const row = page.locator(".page-header");
  await expect(row.locator(".page-header-crumbs li")).toHaveText(["Admin", "Deployments"]);
  await expect(row.locator(".page-header-crumbs a")).toHaveAttribute("href", "/admin/dashboard");
  const title = row.locator("h1.page-header-title");
  await expect(title).toHaveText("Deployments");
  expect(await title.evaluate((el) => getComputedStyle(el).fontSize)).toBe("30px");
  await expect(row.locator(".page-header-actions a.page-header-action", { hasText: "New Task" })).toBeVisible();
  for (const name of ["Epics", "Intelligence", "Pokédex", "Pipeline", "Insights", "Recent"]) {
    await expect(row.locator(".page-header-links a", { hasText: name })).toHaveCount(1);
  }
  const [crumb, heading] = [await row.locator(".page-header-crumbs").boundingBox(), await title.boundingBox()];
  expect(crumb.y + crumb.height).toBeLessThanOrEqual(heading.y + 1);
});

test("a depth-3 page trails Admin, Deployments, All Deployments, and a phone gets one parent link", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/deployments/all");
  await expect(page.locator(".page-header-crumbs li")).toHaveText(["Admin", "Deployments", "All Deployments"]);

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator(".page-header-crumbs")).toBeHidden();
  const parent = page.locator(".page-header-parent");
  await expect(parent).toBeVisible();
  await expect(parent).toHaveText(/Deployments/);
  await expect(parent).toHaveAttribute("href", "/deployments");
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);
});

test("forward slides left; a crumb up the trail and browser Back slide right", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await recordMoves(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/deployments");
  await page.waitForFunction(() => window.Turbo);

  await visitBy(page, () => page.locator(".page-header-links a", { hasText: "Epics" }).click());
  await expect(page).toHaveURL(/\/epics$/);
  await visitBy(page, () => page.locator(".page-header-crumbs a", { hasText: "Deployments" }).click());
  await expect(page).toHaveURL(/\/deployments$/);
  await page.waitForTimeout(200); // Turbo ignores a popstate during the page's own load.
  await visitBy(page, () => page.goBack());
  await expect(page).toHaveURL(/\/epics$/);

  expect(await page.evaluate(() => window.__moves)).toEqual(["slide-left", "slide-right", "slide-right"]);
});
