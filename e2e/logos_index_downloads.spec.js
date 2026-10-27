// [e2e] The /logos table's downloads (task logos-index-download-formats; Alex McRitchie 2026-10-27): each row's Download
// Navbar, Stacked and Icon links sit in the brand column; the header's Download format (PNG, SVG, JPEG) opens on PNG
// and sets every row's links; a PNG or JPEG is drawn in the browser at the type's default preset, a JPEG on the tone's
// solid background.
const fs = require("fs");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const row = (page, brand) => page.locator(`[data-test='logo-brand-row'][data-brand='${brand}']`);
const link = (page, brand, type) => row(page, brand).locator(`th [data-test='logo-sample-download'][data-type='${type}']:visible`);

async function open(page, path) {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(path);
}

async function download(page, locator) {
  const [file] = await Promise.all([page.waitForEvent("download"), locator.click()]);
  return { bytes: fs.readFileSync(await file.path()), name: file.suggestedFilename() };
}

test("the table opens on PNG and a row's Navbar downloads as an 800-wide transparent PNG", async ({ page }) => {
  await open(page, "/logos");
  const control = page.locator("[data-test='download-format-control']");
  await expect(control).toBeVisible();
  await expect(control.locator("[aria-current='true']")).toHaveText("PNG");
  await expect(row(page, "studio").locator("th [data-test='logo-sample-download']:visible")).toHaveText(["Download Navbar", "Download Stacked", "Download Icon"]);

  const { bytes, name } = await download(page, link(page, "studio", "navbar"));
  expect(bytes.subarray(0, 8).toString("hex")).toBe("89504e470d0a1a0a");
  expect(bytes.readUInt32BE(16)).toBe(800);
  expect(bytes[25]).toBe(6); // RGBA: transparent
  expect(name).toMatch(/^studio-navbar-.*-800x\d+\.png$/);
});

test("in JPEG a row's Icon downloads as a JPEG at its 512 preset, and SVG gives the SVG itself", async ({ page }) => {
  await open(page, "/logos?download_format=jpeg");
  await expect(page.locator("[data-test='download-format-control'] [aria-current='true']")).toHaveText("JPEG");
  const jpeg = await download(page, link(page, "welding_v2", "icon"));
  expect(jpeg.bytes.subarray(0, 3).toString("hex")).toBe("ffd8ff");
  expect(jpeg.name).toMatch(/^welding_v2-icon-.*-\d+x\d+\.jpg$/);
  expect(jpeg.name).toMatch(/-(512x\d+|\d+x512)\.jpg$/);

  await page.locator("[data-test='download-format-option'][data-format='svg']").click();
  await expect(page).toHaveURL(/download_format=svg/);
  const svg = await download(page, link(page, "welding_v2", "stacked"));
  expect(svg.name).toMatch(/\.svg$/);
  expect(svg.bytes.toString("utf8")).toContain("<svg");
});

// With JavaScript off the control is served hidden and every href is the SVG download:
// test/controllers/logos_index_downloads_test.rb.
