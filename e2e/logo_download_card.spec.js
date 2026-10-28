// [e2e] The brand page's Download card (task logo-download-card; Alex McRitchie 2026-10-14 22:05: "allow for png downloading
// and some preset sizes. There are some integrations that have very specific size requirements and don't accept
// SVGs"). Each tab draws ONE logo with a Download card; a PNG at a preset size is a file of exactly that many pixels,
// read from the PNG's own header, on every type; a custom Width × Height keeps the aspect or, unticked, sets the canvas
// (shown dotted on the logo); and the card sits beside the logo, the controls beside the edit panel.
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

// Picks PNG and a size on the card, clicks Download, and answers the file's header and its suggested name.
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

// Task brand-page-split-layout (Alex McRitchie 2026-10-27: "a px aspect ratio setter … a checkbox for keep aspect ratio
// … a dotted line should appear to show the visual aspect ratio"): Width × Height, kept or free.
test("with Keep aspect ratio a typed width sets the height, and the PNG is that size", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/studio");
  await expect(card(page).locator("input[data-test='download-format-option'][value='png']")).toBeChecked(); // PNG is the default
  await card(page).locator("[data-test='download-size']").selectOption("custom");
  await expect(card(page).locator("[data-test='download-custom']")).toBeVisible();
  await expect(card(page).locator("[data-test='download-keep-aspect']")).toBeChecked();
  await card(page).locator("[data-test='download-custom-width']").fill("1000");
  const natural = await card(page).locator("input[data-test='download-tone-option']:checked")
    .evaluate((input) => [Number(input.dataset.naturalWidth), Number(input.dataset.naturalHeight)]);
  const height = Math.max(1, Math.floor((1000 * natural[1]) / natural[0] + 0.5));
  await expect(card(page).locator("[data-test='download-custom-height']")).toHaveValue(String(height));
  await expect(page.locator("[data-test='download-canvas-outline']")).toBeHidden(); // the canvas is the logo's own shape
  const [download] = await Promise.all([page.waitForEvent("download"), card(page).locator("[data-test='logo-download']").click()]);
  const png = pngHeader(await download.path());
  expect([png.width, png.height]).toEqual([1000, height]);
});

test("without Keep aspect ratio both sides are free, a dotted outline shows the canvas, and the PNG is exactly that size", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/studio?type=stacked");
  await card(page).locator("[data-test='download-size']").selectOption("custom");
  await card(page).locator("[data-test='download-keep-aspect']").uncheck();
  await card(page).locator("[data-test='download-custom-width']").fill("1200");
  await card(page).locator("[data-test='download-custom-height']").fill("630");
  const outline = page.locator("[data-test='download-canvas-outline']");
  await expect(outline).toBeVisible();
  const box = await outline.boundingBox();
  expect(Math.abs(box.width / box.height - 1200 / 630)).toBeLessThan(0.02); // the canvas's own shape
  const logo = await page.locator("[data-test='logo-frame'] img:visible").first().boundingBox();
  expect(box.x).toBeLessThanOrEqual(logo.x + 1); // around the logo
  expect(box.x + box.width).toBeGreaterThanOrEqual(logo.x + logo.width - 1);
  const [download] = await Promise.all([page.waitForEvent("download"), card(page).locator("[data-test='logo-download']").click()]);
  const png = pngHeader(await download.path());
  expect([png.width, png.height]).toEqual([1200, 630]);

  await card(page).locator("[data-test='download-keep-aspect']").check(); // kept again: the side last typed stays, the other follows
  await expect(outline).toBeHidden();
  await expect(card(page).locator("[data-test='download-custom-height']")).toHaveValue("630");
  await expect(card(page).locator("[data-test='download-custom-width']")).not.toHaveValue("1200");
});

// Task brand-page-split-layout: at desktop width the Download card sits beside the logo, the two one height, and the
// controls beside the edit panel under them; guides take the Download card away; a phone is one column.
test("every tab puts Download beside the logo and the controls beside Edit; one column on a phone", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");

  for (const path of ["/logos/studio", "/logos/studio?type=stacked", "/logos/studio?type=icon"]) {
    await page.goto(path);
    await expect(page.locator("[data-test='logo-type']")).toHaveAttribute("data-layout", "split");
    const download = await card(page).boundingBox();
    const logo = await page.locator("[data-test='logo-example']").boundingBox();
    const controls = await page.locator("[data-test='logo-control-card']").boundingBox();
    const edit = await page.locator("[data-test='edit-panel']").boundingBox();
    expect(logo.x).toBeGreaterThanOrEqual(download.x + download.width); // the logo beside the Download card
    expect(Math.abs(logo.y - download.y)).toBeLessThan(2);
    expect(Math.abs(logo.width - download.width)).toBeLessThan(2); // halves
    expect(Math.abs(logo.height - download.height)).toBeLessThan(2); // and of one height
    expect(controls.y).toBeGreaterThanOrEqual(logo.y + logo.height);
    expect(edit.x).toBeGreaterThanOrEqual(controls.x + controls.width); // the controls beside the edit panel
    expect(Math.abs(edit.y - controls.y)).toBeLessThan(2);
  }

  await page.goto("/logos/studio?type=stacked&guides=1");
  await expect(page.locator("[data-test='logo-type']")).toHaveAttribute("data-layout", "row");
  await expect(card(page)).toHaveCount(0); // the guide drawing takes the row
  const logo = await page.locator("[data-test='logo-example']").boundingBox();
  expect(logo.width).toBeGreaterThan(1000);

  await page.setViewportSize({ width: 375, height: 800 });
  await page.goto("/logos/studio?type=stacked");
  const top = await card(page).boundingBox();
  const shown = await page.locator("[data-test='logo-example']").boundingBox();
  expect(shown.y).toBeGreaterThanOrEqual(top.y + top.height);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
});
