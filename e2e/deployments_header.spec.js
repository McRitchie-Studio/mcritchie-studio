const { test, expect } = require("@playwright/test");

// [e2e] The /deployments and /triage headers on the engine's four kinds of control
// (Alex McRitchie 2026-11-06, studio-engine docs/PAGE_HEADER.md "The four kinds of
// control"; task hub-header-controls). Before, the row held a grey "Triage" pill, a
// purple "New Task" button and a black "Links" button: three looks for one row. Now the
// board views are one tab group with the current page marked, Stages and Docs sit in the
// Links menu, and New Task is the one action. Every kind stands at one height.

const ROW = ".page-header";

test("/deployments: one action, the board tabs with Deployments marked, and a Links menu that opens", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/deployments");
  const row = page.locator(ROW);

  // The one action.
  const action = row.locator("a.page-header-action");
  await expect(action).toHaveCount(1);
  await expect(action).toHaveText("New Task");
  await expect(action).toHaveAttribute("href", "/tasks/new");
  await expect(row.locator(".page-header-actions .btn-primary")).toHaveCount(1);

  // The tabs: Deployments is the current one, Triage is one click away.
  const tabs = row.locator("nav.page-header-tabs[aria-label='Board views']");
  await expect(tabs).toBeVisible();
  await expect(tabs.locator("a[aria-current='page']")).toHaveCount(1);
  await expect(tabs.locator("a[aria-current='page']")).toHaveAttribute("href", "/deployments");
  const triage = tabs.locator("a[href='/triage']");
  await expect(triage).toBeVisible();
  await expect(triage).not.toHaveAttribute("aria-current", /.+/);

  // The Links menu: closed at rest, open on a click, closed again on Escape.
  const button = row.locator(".page-header-menu-button");
  await expect(button).toHaveText(/Links/);
  const list = row.locator(".page-header-menu-list");
  await expect(list).toBeHidden();
  await button.click();
  await expect(list).toBeVisible();
  await expect(button).toHaveAttribute("aria-expanded", "true");
  await expect(list.locator("a")).toHaveText(["Stages", "Docs"]);
  await expect(list.locator("a[data-test='deployment-link-menu-stages']")).toHaveAttribute("href", "/stages");
  await page.keyboard.press("Escape");
  await expect(list).toBeHidden();
  await expect(button).toHaveAttribute("aria-expanded", "false");

  // One height: the tab, the menu button and the action share .btn-sm's box.
  const heights = await Promise.all(
    [triage, button, action].map((el) => el.evaluate((node) => Math.round(node.getBoundingClientRect().height)))
  );
  expect(Math.max(...heights) - Math.min(...heights), `heights ${heights.join(", ")}`).toBeLessThanOrEqual(1);
});

test("the Triage tab leads to /triage, where Triage is the marked tab", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/deployments");
  await page.locator(`${ROW} nav.page-header-tabs a[href='/triage']`).click();
  await expect(page).toHaveURL(/\/triage$/);

  const tabs = page.locator(`${ROW} nav.page-header-tabs[aria-label='Board views']`);
  await expect(tabs.locator("a[aria-current='page']")).toHaveAttribute("href", "/triage");
  await expect(tabs.locator("a[href='/deployments']")).toBeVisible();
  await expect(page.locator(`${ROW} [data-test='triage-open-count']`)).toHaveCount(0);
  await expect(page.locator("[data-test='triage-open-count']")).toBeVisible();
});

test("at phone width the /deployments header controls stay inside the viewport", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/deployments");
  const row = page.locator(ROW);
  await expect(row.locator("a.page-header-action")).toBeVisible();
  await expect(row.locator(".page-header-menu-button")).toBeVisible();
  await expect(row.locator("nav.page-header-tabs a[aria-current='page']")).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);
});
