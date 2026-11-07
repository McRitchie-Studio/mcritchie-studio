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

// /devops is the root of the DevOps trail (devops-namespace), so it draws no trail of its
// own; the pages under it start theirs at DevOps.
test("/devops wears the page header: no trail at the root, h2-size title, actions right, links under it", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/devops");
  const row = page.locator(".page-header");
  await expect(row.locator(".page-header-crumbs")).toHaveCount(0);
  const title = row.locator("h1.page-header-title");
  await expect(title).toHaveText("Deployments");
  expect(await title.evaluate((el) => getComputedStyle(el).fontSize)).toBe("30px");
  await expect(row.locator(".page-header-actions a.page-header-action", { hasText: "New Task" })).toBeVisible();
  for (const name of ["Epics", "Intelligence", "Pokédex", "Pipeline", "Insights", "Recent"]) {
    await expect(row.locator(".page-header-links a", { hasText: name })).toHaveCount(1);
  }
});

test("a release-list page trails DevOps, All Deployments, and a phone gets one parent link", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/devops/deployments");
  await expect(page.locator(".page-header-crumbs li")).toHaveText(["DevOps", "All Deployments"]);
  await expect(page.locator(".page-header-crumbs a").first()).toHaveAttribute("href", "/devops");
  const [crumb, heading] = [await page.locator(".page-header-crumbs").boundingBox(), await page.locator("h1.page-header-title").boundingBox()];
  expect(crumb.y + crumb.height).toBeLessThanOrEqual(heading.y + 1);

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator(".page-header-crumbs")).toBeHidden();
  const parent = page.locator(".page-header-parent");
  await expect(parent).toBeVisible();
  await expect(parent).toHaveText(/DevOps/);
  await expect(parent).toHaveAttribute("href", "/devops");
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);
});

test("forward slides left; a crumb up the trail and browser Back slide right", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await recordMoves(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/devops");
  await page.waitForFunction(() => window.Turbo);

  await visitBy(page, () => page.locator(".page-header-links a", { hasText: "Epics" }).click());
  await expect(page).toHaveURL(/\/devops\/epics$/);
  await visitBy(page, () => page.locator(".page-header-crumbs a", { hasText: "DevOps" }).click());
  await expect(page).toHaveURL(/\/devops$/);
  // Turbo ignores a popstate until the window's load has fired and one microtask has
  // passed (its History#pageLoaded); wait on that state, then one frame, not a clock.
  await page.waitForFunction(() => document.readyState === "complete");
  await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => done())));
  await visitBy(page, () => page.goBack());
  await expect(page).toHaveURL(/\/devops\/epics$/);

  expect(await page.evaluate(() => window.__moves)).toEqual(["slide-left", "slide-right", "slide-right"]);
});
