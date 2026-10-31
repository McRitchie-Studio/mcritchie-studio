// [e2e] Each brand's Google marketing kit on /logos (tasks marketing-kit-on-logos, logos-table-columns-tidy): in the Apps
// and kits column, a chip with the Google Drive mark, the account that owns the kit and its status mark on the right,
// opening the Drive folder in a new tab; a brand with no kit has a hollow "No Google kit" chip. Seeded in e2e/seed.rb
// (turf has a kit; no spec saves turf's logos, so it stays Up to date).
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const chip = (page, brand) => page.locator(`[data-test='kit-chip'][data-kind='google'][data-brand='${brand}']`).first();

async function open(page, width) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos");
}

test("a brand with a Google kit has an Up to date chip that opens its Drive folder", async ({ page }) => {
  await open(page, 1280);
  const turf = chip(page, "turf");
  await expect(turf).toBeVisible();
  await expect(turf).toHaveAttribute("data-status", "current");
  await expect(turf).toHaveAccessibleName("Google kit team@mcritchie.studio: Up to date");
  await expect(turf.locator("[data-test='google-drive-icon']")).toBeVisible();
  await expect(turf.locator("[data-test='kit-chip-name']")).toHaveText("team@mcritchie.studio");
  await expect(turf.locator("[data-test='kit-chip-mark']")).toHaveAttribute("data-mark", "done");
  await expect(turf).toHaveAttribute("href", "https://drive.google.com/drive/folders/e2e-turf-kit");
  await expect(turf).toHaveAttribute("target", "_blank");
  await expect(turf).toHaveAttribute("title", /^Google kit team@mcritchie\.studio: Up to date\. Kit /);

  const none = chip(page, "industries");
  await expect(none).toBeVisible();
  await expect(none).toHaveText("No Google kit");
  await expect(none.locator("[data-test='kit-chip-mark']")).toHaveAttribute("data-mark", "none");
  expect(await none.evaluate((el) => el.tagName)).toBe("SPAN");
});

test("on a phone the Google kit chip and its mark stay on screen", async ({ page }) => {
  await open(page, 390);
  const turf = chip(page, "turf");
  await turf.scrollIntoViewIfNeeded();
  const mark = turf.locator("[data-test='kit-chip-mark']");
  await expect(mark).toBeVisible();
  const box = await mark.boundingBox();
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(390);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});
