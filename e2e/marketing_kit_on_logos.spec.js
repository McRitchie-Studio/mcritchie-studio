// [e2e] Each brand's Google marketing kit on /logos (task marketing-kit-on-logos; Alex McRitchie 2026-10-28): under the
// brand's downloads, the Google Drive mark, the account that owns the kit, its status and an Open link to the Drive folder in a new tab; a brand with no kit
// says "No Google kit". Seeded in e2e/seed.rb (turf has a kit; no spec saves turf's logos, so it stays Up to date).
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const line = (page, brand) => page.locator(`[data-test='marketing-kit-status'][data-brand='${brand}']`).first();

async function open(page, width) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos");
}

test("a brand with a Google kit shows Up to date and an Open link to its Drive folder", async ({ page }) => {
  await open(page, 1280);
  const turf = line(page, "turf");
  await expect(turf).toBeVisible();
  await expect(turf).toHaveAttribute("data-status", "current");
  await expect(turf.locator("[data-test='google-drive-icon']")).toBeVisible();
  await expect(turf.locator("[data-test='marketing-kit-owner']")).toHaveText("team@mcritchie.studio");
  await expect(turf).toContainText("Up to date");
  const link = turf.locator("[data-test='marketing-kit-link']");
  await expect(link).toBeVisible();
  await expect(link).toHaveText("Open");
  await expect(link).toHaveAttribute("href", "https://drive.google.com/drive/folders/e2e-turf-kit");
  await expect(link).toHaveAttribute("target", "_blank");
  await expect(turf).toHaveAttribute("title", /^Google kit owned by team@mcritchie\.studio: /);

  const none = line(page, "industries");
  await expect(none).toBeVisible();
  await expect(none).toHaveText("No Google kit");
  await expect(none.locator("a")).toHaveCount(0);
});

test("on a phone the Google kit line and its Open link stay on screen", async ({ page }) => {
  await open(page, 390);
  const link = line(page, "turf").locator("[data-test='marketing-kit-link']");
  await link.scrollIntoViewIfNeeded();
  await expect(link).toBeVisible();
  const box = await link.boundingBox();
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(390);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});
