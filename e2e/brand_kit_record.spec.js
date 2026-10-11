// [e2e] The brand kit record (task brand-kit-record): on a brand page's Stacked tab, an edited
// logo is saved as the brand's kit choice with a text version picked beside the button; the
// /logos table then draws that choice, marked Saved, and its download is the saved logo;
// Clear saved choice puts the default back. And the Kit originals card uploads an SVG and a
// PNG, shows both as pictures, and deletes them. Each test clears what it saved, so the
// other /logos specs see the defaults.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const SVG = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#C8661F"/></svg>');
// A 1x1 PNG.
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");

async function open(page, path, width = 1280) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(path);
}

const stackedTile = (page, brand) => page.locator(`[data-test='logo-cluster'][data-brand='${brand}'] [data-test='logo-sample'][data-type='stacked']`);

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("saving a stacked choice with an edit shows it in the table, marked Saved, and clearing it brings the default back", async ({ page }) => {
  await open(page, "/logos/industries?type=stacked&form=tagline&ending_colour=C8661F");
  const choice = page.locator("[data-test='kit-choice']");
  await expect(choice.locator("[data-test='kit-save-text']")).toHaveValue("first");
  await choice.locator("[data-test='kit-save-text']").selectOption("second");
  await choice.locator("[data-test='kit-save']").click();

  await page.waitForURL(/\/logos\/industries\?.*form=tagline/);
  await expect(page.getByText("Saved the Stacked Logo kit choice: with tagline, second word leads, ending Forge Orange.")).toBeVisible();
  await expect(page.locator("[data-test='kit-status']")).toContainText(/Kit: saved \w{3} \d+, \d{4} by alex@test\.com/);
  await expect(page.locator("[data-test='kit-pick'][data-type='stacked'] [data-test='kit-pick-summary']")).toHaveText("With tagline, second word leads, ending Forge Orange");

  await page.goto("/logos");
  const tile = stackedTile(page, "industries");
  await expect(tile).toHaveAttribute("data-saved", "true");
  await expect(tile.locator("[data-test='logo-badge']")).toHaveText("Stacked · Saved");
  const src = await tile.locator("img:visible").getAttribute("src");
  expect(src).toContain("form=tagline");
  expect(src).toContain("text=second");
  expect(src).toContain("ending_colour=C8661F");
  await expect.poll(() => tile.locator("img:visible").evaluate((img) => img.complete && img.naturalWidth > 0)).toBe(true);

  const download = page.locator("[data-test='logo-brand-row'][data-brand='industries'] [data-test='logo-sample-download'][data-type='stacked']:visible");
  const response = await page.request.get(await download.getAttribute("href"));
  expect(response.headers()["content-disposition"]).toMatch(/industries-stacked-tagline-second-(light|dark)-custom\.svg/);
  expect(await response.text()).toContain('fill="#C8661F"');

  await page.goto("/logos/industries?type=stacked");
  await page.locator("[data-test='kit-clear']").click();
  await expect(page.getByText("Cleared the Stacked Logo kit choice. The brand shows its default again.")).toBeVisible();
  await page.goto("/logos");
  await expect(stackedTile(page, "industries")).toHaveAttribute("data-saved", "false");
  await expect(stackedTile(page, "industries").locator("[data-test='logo-badge']")).toHaveText("Stacked");
});

test("uploading an SVG and a PNG original shows both as pictures on the brand page, and each can be deleted", async ({ page }) => {
  await open(page, "/logos/welding?type=icon");
  const card = page.locator("[data-test='kit-originals']");
  await expect(card).toContainText("The originals the logos were derived from.");
  await card.locator("input[type='file']").setInputFiles([
    { name: "welding-kit.svg", mimeType: "image/svg+xml", buffer: SVG },
    { name: "welding-kit.png", mimeType: "image/png", buffer: PNG }
  ]);
  await card.locator("[data-test='kit-original-upload']").click();

  await page.waitForURL(/\/logos\/welding\?type=icon#kit-originals/);
  await expect(page.getByText("Uploaded 2 originals: welding-kit.svg and welding-kit.png.")).toBeVisible();
  const items = page.locator("[data-test='kit-original']");
  await expect(items).toHaveCount(2);
  await expect(items.locator("[data-test='kit-original-name']")).toHaveText(["welding-kit.svg", "welding-kit.png"]);
  await expect(items.nth(0).locator("[data-test='kit-original-meta']")).toContainText(/SVG · \d+ Bytes · uploaded/);
  for (const preview of await page.locator("img[data-test='kit-original-preview']").all()) {
    await expect.poll(() => preview.evaluate((img) => img.complete && img.naturalWidth > 0)).toBe(true);
  }

  const fits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(fits).toBe(true);

  await items.nth(0).locator("[data-test='kit-original-delete']").click();
  await expect(page.getByText("Removed welding-kit.svg.")).toBeVisible();
  await page.locator("[data-test='kit-original'] [data-test='kit-original-delete']").click();
  await expect(page.locator("[data-test='kit-originals-empty']")).toBeVisible();
});

test("at 375 the kit cards fit without the page scrolling sideways", async ({ page }) => {
  await open(page, "/logos/welding_v2?type=stacked", 375);
  await expect(page.locator("[data-test='kit-choice']")).toBeVisible();
  await expect(page.locator("[data-test='kit-card']")).toBeVisible();
  await expect(page.locator("[data-test='kit-originals']")).toBeVisible();
  const fits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(fits).toBe(true);
});
