const { test, expect } = require("@playwright/test");

// [e2e] The hub's ops pages on the engine page header (hub-ops-page-headers). Sticky
// ends where the row's parent ends, so each pin test puts a spacer after the page's
// last content block and reads the row after a 1500px scroll. Headless Chrome will not
// go below 500px, so phone tests emulate a 390px device and assert window.innerWidth.
// /stack and the Insight Bank use the admin session; /privacy runs signed out.

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

async function oneHeader(page, path, title) {
  await page.goto(path);
  const row = page.locator(".page-header");
  await expect(row).toHaveCount(1);
  await expect(page.locator("h1")).toHaveCount(1);
  await expect(row.locator("h1.page-header-title")).toHaveText(title);
  return row;
}

test("/stack at desktop: the trail reaches the Basement, and the row stays pinned after a 1500px scroll", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const row = await oneHeader(page, "/stack", "Every client's stack");
  await expect(row.locator(".page-header-crumbs li")).toHaveText(["Admin", "Basement", "Stack"]);
  expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
  expect(await pinGapAfterScroll(page, "[data-test='stack-page'] > *")).toBe(0);
});

test("the Insight Bank at desktop: the header wears the dark surface's palette, and pins", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.addInitScript(() => localStorage.setItem("theme", "light"));
  const row = await oneHeader(page, "/devops/insights", "💡 Insight Bank");
  // The surface is fixed-dark on a light desktop: the title reads light on it.
  const colour = await row.locator("h1").evaluate((el) => getComputedStyle(el).color);
  expect(colour).toBe("rgb(230, 237, 243)");
  await expect(row.locator(".page-header-menu-button")).toHaveText(/Links/);
  expect(await pinGapAfterScroll(page, "#mason-insights > *")).toBe(0);
  const stuckBg = await row.evaluate((el) => getComputedStyle(el).backgroundColor);
  expect(stuckBg).toBe("rgb(13, 17, 23)");
});

test.describe("on a 390px phone", () => {
  test.use(PHONE);

  test("/stack at 390px in dark mode: one parent link, no sideways scroll, pinned after a 1500px scroll", async ({ page }) => {
    await page.addInitScript(() => localStorage.setItem("theme", "dark"));
    const row = await oneHeader(page, "/stack", "Every client's stack");
    expect(await page.evaluate(() => window.innerWidth)).toBe(390);
    await expect(page.locator("html")).toHaveClass(/\bdark\b/);
    await expect(row.locator(".page-header-crumbs")).toBeHidden();
    const parent = row.locator("a.page-header-parent");
    await expect(parent).toBeVisible();
    await expect(parent).toContainText("Basement");
    const box = await row.boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(390);
    expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
    expect(await pinGapAfterScroll(page, "[data-test='stack-page'] > *")).toBe(0);
  });

  test("/agents/activities at 390px: the row fits the dark section's narrow gutter with no sideways scroll", async ({ page }) => {
    const row = await oneHeader(page, "/agents/activities", "Activities");
    expect(await page.evaluate(() => window.innerWidth)).toBe(390);
    const box = await row.boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(390);
    expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
  });

  test.describe("signed out", () => {
    test.use({ storageState: { cookies: [], origins: [] } });

    test("/privacy at 390px: the long title wraps in the row, no trail, pinned after a 1500px scroll", async ({ page }) => {
      const row = await oneHeader(page, "/privacy", "Privacy Policy and Messaging Terms and Conditions");
      expect(await page.evaluate(() => window.innerWidth)).toBe(390);
      await expect(row.locator(".page-header-trail")).toHaveCount(0);
      expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
      expect(await pinGapAfterScroll(page, "[data-test='privacy-page'] > *")).toBe(0);
    });
  });
});
