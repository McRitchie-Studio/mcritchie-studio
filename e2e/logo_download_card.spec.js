// [e2e] The brand page's Download card (task logo-download-card; Alex McRitchie 2026-10-14 22:05: "allow for png downloading
// and some preset sizes. There are some integrations that have very specific size requirements and don't accept
// SVGs"). Each tab draws ONE logo with a Download card; a PNG at a preset size is a file of exactly that many pixels,
// read from the PNG's own header, on every type; a custom width keeps the aspect; and the Navbar tab is a row (the
// logo over the cards) while the Stacked tab is a column (the logo beside them).
const fs = require("fs");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// The PNG's own size: the IHDR chunk's width and height, and its colour type (6 is RGBA: it has an alpha channel).
function pngHeader(path) {
  const bytes = fs.readFileSync(path);
  expect(bytes.subarray(0, 8).toString("hex")).toBe("89504e470d0a1a0a");
  expect(bytes.subarray(12, 16).toString("ascii")).toBe("IHDR");
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), colourType: bytes[25] };
}

const card = (page) => page.locator("[data-test='download-card']");

// Picks PNG and a size on the card, clicks Download PNG, and answers the file's header and its suggested name.
async function downloadPng(page, size) {
  await card(page).locator("label", { hasText: "PNG" }).click();
  await card(page).locator("[data-test='download-size']").selectOption(size);
  const [download] = await Promise.all([page.waitForEvent("download"), card(page).locator("[data-test='logo-download']").click()]);
  return { ...pngHeader(await download.path()), name: download.suggestedFilename() };
}

// The preset the card offers for the checked tone, as the server computed it.
async function preset(page, key) {
  return card(page).locator("input[data-test='download-tone-option']:checked").evaluate((input, k) => JSON.parse(input.dataset.presets).find((p) => p.key === k), key);
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
// Alex McRitchie, 2026-10-14 22:35: "the default should be to download the true aspect ratio but there should be a button to use
// 1:1 aspect ratio". Studio's chest is about 662 × 538, so its 512 preset is 512 × 416, or 512 × 512 padded.
test("the Studio icon at 512 downloads in its true aspect, 512 × 416, with transparency, named after the SVG", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/studio?type=icon");
  await expect(card(page)).toHaveCount(1);
  const png = await downloadPng(page, "512");
  expect([png.width, png.height]).toEqual([512, 416]);
  expect(png.colourType).toBe(6);
  expect(png.name).toMatch(/^studio-icon-(light|dark)-512x416\.png$/);
  await expect(card(page).locator("[data-test='download-summary']")).toContainText("true aspect");
});

test("the Studio icon at 512 with 1:1 square downloads 512 × 512, padded", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/studio?type=icon");
  await card(page).locator("label", { hasText: "PNG" }).click();
  await expect(card(page).locator("[data-test='download-square-toggle']")).toBeVisible();
  await card(page).locator("[data-test='download-square']").check();
  await expect(card(page).locator("[data-test='download-summary']")).toContainText("1:1 square, padded");
  const png = await downloadPng(page, "512");
  expect([png.width, png.height]).toEqual([512, 512]);
  expect(png.name).toMatch(/^studio-icon-(light|dark)-512x512\.png$/);
});

test("the Navbar tab's 800 wide preset downloads a PNG of exactly the preset's pixels", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/studio");
  await expect(page.locator("[data-test='logo-example']")).toHaveCount(1);
  const expected = await preset(page, "w800");
  expect(expected.width).toBe(800);
  const png = await downloadPng(page, "w800");
  expect([png.width, png.height]).toEqual([800, expected.height]);
  expect(png.name).toMatch(/^studio-navbar-rule4-second-(light|dark)-800x\d+\.png$/);
});

test("the Stacked tab's 400 wide preset downloads a PNG of exactly the preset's pixels, on a solid background", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/industries?type=stacked");
  await expect(page.locator("[data-test='logo-example']")).toHaveCount(1);
  await card(page).locator("label", { hasText: "PNG" }).click();
  await card(page).locator("label", { hasText: "Solid" }).click();
  await expect(card(page).locator("[data-test='download-background-colour']")).toBeVisible();
  const expected = await preset(page, "w400");
  const png = await downloadPng(page, "w400");
  expect([png.width, png.height]).toEqual([400, expected.height]);
});

test("a custom width keeps the drawing's aspect, and the card says the size before the download", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/studio");
  await card(page).locator("label", { hasText: "PNG" }).click();
  await card(page).locator("[data-test='download-size']").selectOption("custom");
  await expect(card(page).locator("[data-test='download-custom']")).toBeVisible();
  await card(page).locator("[data-test='download-custom-axis']").selectOption("width");
  await card(page).locator("[data-test='download-custom-value']").fill("1000");
  const natural = await card(page).locator("input[data-test='download-tone-option']:checked")
    .evaluate((input) => [Number(input.dataset.naturalWidth), Number(input.dataset.naturalHeight)]);
  const height = Math.max(1, Math.floor((1000 * natural[1]) / natural[0] + 0.5));
  await expect(card(page).locator("[data-test='download-summary']")).toContainText(`1000 × ${height} px`);
  const [download] = await Promise.all([page.waitForEvent("download"), card(page).locator("[data-test='logo-download']").click()]);
  const png = pngHeader(await download.path());
  expect([png.width, png.height]).toEqual([1000, height]);
});

test("the Navbar tab is a row and the Stacked tab a column at desktop width; both one column on a phone", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/logos/studio");
  await expect(page.locator("[data-test='logo-type']")).toHaveAttribute("data-layout", "row");
  let logo = await page.locator("[data-test='logo-example']").boundingBox();
  let download = await card(page).boundingBox();
  let edit = await page.locator("[data-test='edit-panel']").boundingBox();
  expect(download.y).toBeGreaterThanOrEqual(logo.y + logo.height); // the logo spans the page, the cards under it
  expect(edit.x).toBeGreaterThanOrEqual(download.x + download.width); // the Download card and the edit panel side by side
  expect(logo.width).toBeGreaterThan(download.width + edit.width);

  await page.goto("/logos/studio?type=stacked");
  await expect(page.locator("[data-test='logo-type']")).toHaveAttribute("data-layout", "column");
  logo = await page.locator("[data-test='logo-example']").boundingBox();
  download = await card(page).boundingBox();
  edit = await page.locator("[data-test='edit-panel']").boundingBox();
  expect(download.x).toBeGreaterThanOrEqual(logo.x + logo.width); // the logo on the left, the cards on the right
  expect(Math.abs(download.y - logo.y)).toBeLessThan(2);
  expect(edit.y).toBeGreaterThanOrEqual(download.y + download.height); // the cards stack in their column

  await page.setViewportSize({ width: 375, height: 800 });
  await page.goto("/logos/studio?type=stacked");
  logo = await page.locator("[data-test='logo-example']").boundingBox();
  download = await card(page).boundingBox();
  expect(download.y).toBeGreaterThanOrEqual(logo.y + logo.height);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
});
