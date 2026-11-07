const { test, expect } = require("@playwright/test");

// [e2e] Two admin pages on the engine page header (task admin-pages-standard-header):
// a logos brand page, whose type tabs are the header's tabs (style S4 before), and /books,
// a title and a lead (style S9 before). At desktop width and at 390px: the row, its one h1,
// the crumb trail (one parent link on a phone), no sideways scroll, and the type tabs work.
// The admin's session is the suite's shared storage state (e2e/global-setup.js).

const VIEWPORTS = {
  desktop: { name: "desktop", width: 1440, height: 900 },
  phone: { name: "phone", width: 390, height: 844 },
};

async function noSidewaysScroll(page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);
}

async function expectTrail(page, viewport, labels, parentHref) {
  const row = page.locator(".page-header");
  if (viewport.name === "desktop") {
    await expect(row.locator(".page-header-crumbs li")).toHaveText(labels);
    await expect(row.locator(".page-header-parent")).toBeHidden();
  } else {
    await expect(row.locator(".page-header-crumbs")).toBeHidden();
    const parent = row.locator(".page-header-parent");
    await expect(parent).toBeVisible();
    await expect(parent).toHaveText(new RegExp(labels[labels.length - 2]));
    await expect(parent).toHaveAttribute("href", parentHref);
  }
}

async function logosBrandPage(page, viewport) {
  await page.setViewportSize({ width: viewport.width, height: viewport.height });
  await page.goto("/logos/turf");

  const row = page.locator(".page-header[data-test='logo-header']");
  await expect(row).toBeVisible();
  await expect(page.locator("h1")).toHaveCount(1);
  const title = row.locator("h1.page-header-title");
  await expect(title).toBeVisible();
  const name = (await title.textContent()).trim();
  await expectTrail(page, viewport, ["Admin", "Logos", name], "/logos");
  await expect(page.locator("[data-test='logo-header-bar'] [data-test='context-form']")).toBeVisible();
  await noSidewaysScroll(page);

  const tabs = row.locator("nav[aria-label='Logo type'] a[data-test='logo-tab']");
  await expect(tabs).toHaveCount(4);
  await expect(row.locator("a[data-test='logo-tab'][aria-current='page']")).toHaveAttribute("data-type", "navbar");

  await row.locator("a[data-test='logo-tab'][data-type='stacked']").click();
  await expect(page).toHaveURL(/\/logos\/turf\?(.+&)?type=stacked/);
  await expect(row.locator("a[data-test='logo-tab'][aria-current='page']")).toHaveAttribute("data-type", "stacked");
  await expect(page.locator("[data-test='logo-type'][data-type='stacked']")).toBeVisible();
  await expect(page.locator("h1")).toHaveCount(1);
  await noSidewaysScroll(page);
}

async function booksPage(page, viewport) {
  await page.setViewportSize({ width: viewport.width, height: viewport.height });
  await page.goto("/books");

  const row = page.locator(".page-header");
  await expect(row).toBeVisible();
  await expect(page.locator("h1")).toHaveCount(1);
  await expect(row.locator("h1.page-header-title")).toHaveText("Books");
  await expectTrail(page, viewport, ["Admin", "Books"], "/admin/dashboard");
  await expect(page.locator("[data-test='books-page']")).toContainText("Review and confirm what each bank line was.");
  await noSidewaysScroll(page);
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("a logos brand page at desktop: the header, its trail, and the type tabs switch the view", async ({ page }) => {
  await logosBrandPage(page, VIEWPORTS.desktop);
});

test("a logos brand page at 390px: the header, its parent link, and the type tabs switch the view", async ({ page }) => {
  await logosBrandPage(page, VIEWPORTS.phone);
});

test("/books at desktop: the header, its one h1, its trail and the lead under it", async ({ page }) => {
  await booksPage(page, VIEWPORTS.desktop);
});

test("/books at 390px: the header, its one h1, its parent link and the lead under it", async ({ page }) => {
  await booksPage(page, VIEWPORTS.phone);
});
