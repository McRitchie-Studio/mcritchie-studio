const { test, expect } = require("@playwright/test");

// [e2e] The hub's NFL and people pages on the engine page header (task
// hub-remaining-page-headers). /nfl-coaches was an "NFL Hub" back link over a gradient
// hero; /people/:slug was the name as an h1 inside the profile card. Each now renders
// studio/page_header as a direct child of the page's long container, so the row stays
// pinned under the navbar for the length of the page. Two lessons from the review of
// admin-pages-standard-header: sticky ends where the row's parent ends, so the pin is
// read after a 1500px scroll on two pages; and headless Chrome will not shrink a window
// below 500px, so the phone tests emulate a 390px device and assert window.innerWidth.
// The seeded pages are short, so each pin test lengthens the page's CONTENT first: a
// spacer after the page's last content block, in that block's own parent. A row that sits
// in a wrapper apart from the content still scrolls away, and the test reads it.
// The admin's session is the suite's shared storage state (e2e/global-setup.js).

const COACHES_CONTENT = "main .card";
const PERSON_CONTENT = "main .card";

const PHONE = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 3 };

const sidewaysScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);

// Puts a 3000px spacer after the last element matching `content`, in its parent, scrolls
// 1500px, and answers how far the row's top sits from its pinned place (0 when pinned).
async function pinGapAfterScroll(page, content) {
  const shared = await page.evaluate((selector) => {
    const blocks = document.querySelectorAll(selector);
    const last = blocks[blocks.length - 1];
    const spacer = document.createElement("div");
    spacer.style.height = "3000px";
    spacer.dataset.test = "pin-spacer";
    last.parentElement.insertBefore(spacer, last.nextSibling);
    return document.querySelector(".page-header").parentElement.contains(last);
  }, content);
  expect(shared, "the row and the page content share one container").toBe(true);
  await page.evaluate(() => window.scrollTo(0, 1500));
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(1500);
  return page.evaluate(() => {
    const row = document.querySelector(".page-header");
    return Math.round(row.getBoundingClientRect().top - parseFloat(getComputedStyle(row).top));
  });
}

async function coachesHeader(page) {
  await page.goto("/nfl-coaches");
  const row = page.locator(".page-header");
  await expect(page.locator("h1")).toHaveCount(1);
  await expect(row.locator("h1.page-header-title")).toHaveText("🎙️ NFL Coaches");
  await expect(page.locator("h1.text-white")).toHaveCount(0);
  return row;
}

async function personHeader(page) {
  await page.goto("/people/sean-mcdermott");
  const row = page.locator(".page-header");
  await expect(page.locator("h1")).toHaveCount(1);
  await expect(row.locator("h1.page-header-title")).toHaveText("Sean McDermott");
  await expect(row.locator("a.page-header-action[data-test='person-rename-slug']")).toHaveAttribute(
    "href", "/people/sean-mcdermott/slug");
  return row;
}

test("/nfl-coaches at desktop: the trail reads NFL Hub, and the row stays pinned after a 1500px scroll", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const row = await coachesHeader(page);
  await expect(row.locator(".page-header-crumbs li")).toHaveText(["NFL Hub", "NFL Coaches"]);
  await expect(row.locator(".page-header-crumbs a.page-header-crumb")).toHaveAttribute("href", "/nfl");
  expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
  expect(await pinGapAfterScroll(page, COACHES_CONTENT)).toBe(0);
});

test("/people/:slug at desktop: the trail reaches People, Rename is the action, and the row stays pinned", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const row = await personHeader(page);
  await expect(row.locator(".page-header-crumbs li").last()).toHaveText("Sean McDermott");
  await expect(row.locator(".page-header-crumbs a.page-header-crumb").last()).toHaveAttribute("href", "/people");
  await expect(page.locator("[data-test='person-slug']")).toHaveText("sean-mcdermott");
  expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
  expect(await pinGapAfterScroll(page, PERSON_CONTENT)).toBe(0);
});

test.describe("on a 390px phone", () => {
  test.use(PHONE);

  test("/nfl-coaches at 390px: one parent link, no sideways scroll, dark mode, pinned after a 1500px scroll", async ({ page }) => {
    await page.addInitScript(() => localStorage.setItem("theme", "dark"));
    const row = await coachesHeader(page);
    expect(await page.evaluate(() => window.innerWidth)).toBe(390);
    await expect(page.locator("html")).toHaveClass(/\bdark\b/);
    await expect(row.locator(".page-header-crumbs")).toBeHidden();
    const parent = row.locator("a.page-header-parent");
    await expect(parent).toBeVisible();
    await expect(parent).toHaveAttribute("href", "/nfl");
    await expect(parent).toContainText("NFL Hub");
    const box = await row.boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(390);
    expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
    expect(await pinGapAfterScroll(page, COACHES_CONTENT)).toBe(0);
  });

  test("/people/:slug at 390px: the parent link to People, the action in view, pinned after a 1500px scroll", async ({ page }) => {
    const row = await personHeader(page);
    expect(await page.evaluate(() => window.innerWidth)).toBe(390);
    const parent = row.locator("a.page-header-parent");
    await expect(parent).toBeVisible();
    await expect(parent).toHaveAttribute("href", "/people");
    await expect(row.locator("a.page-header-action")).toBeInViewport();
    expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
    expect(await pinGapAfterScroll(page, PERSON_CONTENT)).toBe(0);
  });
});
