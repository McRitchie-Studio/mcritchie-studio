const { test, expect } = require("@playwright/test");

// [e2e] /tasks/:slug on the engine page header (task task-pages-standard-header; Alex
// McRitchie 2026-11-07, "clean up the DOM and UI"). Before, the page drew its own
// header: an "All Tasks" back link, two outline buttons, and the title as an h2 in a
// card. Now the back link is the crumb trail, the title is the page's one h1, Edit is
// the one action, and Sizing and the assigned agent sit in the Links menu. At 390px
// the trail gives way to one parent link, the meta moves to its phone copy, and the
// row stays inside the viewport. The seeded task timeline-demo (e2e/seed.rb) is
// assigned to alex, so its menu holds both links. The spec only reads it.

const ROW = ".page-header";
const SLUG = "timeline-demo";
const TITLE = "Timeline walkthrough demo";

const noSidewaysScroll = (page) =>
  page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);

test("desktop: crumbs, the one h1, the Edit action and a Links menu that opens", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(`/tasks/${SLUG}`);
  const row = page.locator(ROW);

  // The crumb trail: Admin, Deployments, then the page itself.
  const crumbs = row.locator("nav.page-header-crumbs[aria-label='Breadcrumb']");
  await expect(crumbs).toBeVisible();
  await expect(crumbs.locator("a.page-header-crumb")).toHaveText(["Admin", "Deployments"]);
  await expect(crumbs.locator("a.page-header-crumb").last()).toHaveAttribute("href", "/deployments");
  await expect(crumbs.locator(".page-header-crumb-current")).toHaveText("Task");
  await expect(row.locator("a.page-header-parent")).toBeHidden();

  // The one h1 is the title.
  await expect(page.locator("h1")).toHaveCount(1);
  await expect(row.locator("h1.page-header-title")).toHaveText(TITLE);
  await expect(row.locator(".page-header-meta [data-test='task-slug']")).toHaveText(SLUG);

  // The one action.
  const action = row.locator("a.page-header-action");
  await expect(action).toHaveCount(1);
  await expect(action).toHaveText("Edit");
  await expect(action).toHaveAttribute("href", `/tasks/${SLUG}/edit`);

  // The Links menu: closed at rest, open on a click, closed again on Escape.
  const button = row.locator(".page-header-menu-button");
  const list = row.locator(".page-header-menu-list");
  await expect(list).toBeHidden();
  await button.click();
  await expect(list).toBeVisible();
  await expect(button).toHaveAttribute("aria-expanded", "true");
  await expect(list.locator("a")).toHaveText(["Sizing", "Agent: alex"]);
  await expect(list.locator("[data-test='task-link-sizing']")).toHaveAttribute("href", `/tasks/${SLUG}/sizing`);
  await page.keyboard.press("Escape");
  await expect(list).toBeHidden();

  expect(await noSidewaysScroll(page)).toBeLessThanOrEqual(0);
});

test("390px: the parent link, the title, the action, the menu, the phone meta, and no sideways scroll", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`/tasks/${SLUG}`);
  const row = page.locator(ROW);

  // The trail gives way to one link to the parent.
  const parent = row.locator("a.page-header-parent");
  await expect(parent).toBeVisible();
  await expect(parent).toHaveAttribute("href", "/deployments");
  await expect(parent).toContainText("Deployments");

  await expect(row.locator("h1.page-header-title")).toHaveText(TITLE);
  await expect(row.locator("a.page-header-action")).toBeVisible();

  // The engine hides the meta on a phone; the phone copy carries the stage and slug.
  await expect(row.locator(".page-header-meta")).toBeHidden();
  await expect(page.locator("[data-test='task-meta-phone'] [data-test='task-slug']")).toBeVisible();

  const button = row.locator(".page-header-menu-button");
  await button.click();
  const list = row.locator(".page-header-menu-list");
  await expect(list).toBeVisible();
  await expect(list.locator("a")).toHaveText(["Sizing", "Agent: alex"]);
  const box = await list.boundingBox();
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(390);
  await page.keyboard.press("Escape");
  await expect(list).toBeHidden();

  expect(await noSidewaysScroll(page)).toBeLessThanOrEqual(0);
});
