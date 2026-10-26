// [e2e] The icon as an atomic unit (task kit-icon-atomic-unit; Alex McRitchie 2026-10-11 19:23: "Lets make sure
// the icon is distributed across the other logos"): the Icon tab saves the kit's icon, and every
// Navbar and Stacked Logo, on its tab and in the /logos table, then draws that same icon.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const tabImages = (page) => page.locator("[data-test='logo-type'] img[data-test='logo-image']");
const rowImages = (page) => page.locator("[data-test='logo-cluster'][data-brand='welding_v2'] img");

async function params(locator) {
  return locator.evaluateAll((els) =>
    els.map((el) => Object.fromEntries(new URL(el.getAttribute("src"), location.href).searchParams))
  );
}

async function loaded(page, selector) {
  await page.waitForFunction(
    (sel) => [...document.querySelectorAll(sel)].every((img) => img.complete && img.naturalWidth > 0),
    selector
  );
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("save an icon colouring on the Icon tab and see every logo follow", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");

  // The Icon tab: Alt, with the orange picked in its Edit panel (the panel's own form submits on a change).
  await page.goto("/logos/welding_v2?type=icon&colouring=alt");
  await expect(page.locator("[data-test='edit-row']")).toHaveCount(1);
  await page.locator("[data-test='edit-row'][data-part='icon'] [data-test='edit-swatch'][data-hex='#D7602E']").click();
  await page.waitForURL(/icon_colour=D7602E/);
  await page.locator("[data-test='logo-controls'] [data-test='kit-save-default']").click();
  await page.waitForURL(/\/logos\/welding_v2\?type=icon$/);
  await expect(page.locator("[data-test='kit-default-state']")).toHaveText("Showing the kit default.");

  // The Stacked tab draws it, in Original words.
  await page.goto("/logos/welding_v2?type=stacked");
  await loaded(page, "[data-test='logo-type'] img[data-test='logo-image']");
  const stacked = await params(tabImages(page));
  expect(stacked.length).toBe(2);
  for (const p of stacked) {
    expect(p.colouring).toBe("original");
    expect(p.icon_colouring).toBe("alt");
    expect(p.icon_colour).toBe("D7602E");
  }
  await expect(page.locator("[data-test='kit-icon-note']")).toContainText("Colouring here sets the words");
  // Original words take edits too (task logo-compare-and-original-edits), and the Icon row defers to the kit icon.
  await expect(page.locator("[data-test='edit-kit-icon']")).toBeVisible();
  await expect(page.locator("[data-test='edit-row'][data-part='first']")).toBeVisible();

  // In Alt words, the Edit panel's Icon row defers to the Icon tab.
  await page.goto("/logos/welding_v2?colouring=alt");
  await expect(page.locator("[data-test='edit-kit-icon'] p")).toHaveText("Uses the kit icon. Change it on the Icon tab.");
  for (const p of await params(tabImages(page))) expect(p.icon_colour).toBe("D7602E");

  // The table row: one icon in all three tiles.
  await page.goto("/logos");
  await loaded(page, "[data-test='logo-cluster'][data-brand='welding_v2'] img");
  const row = await params(rowImages(page));
  expect(row.length).toBe(6);
  for (const p of row) expect(p.icon_colour).toBe("D7602E");
  await expect(page.locator("[data-test='logo-cluster'][data-brand='welding_v2'] [data-type='icon'] [data-test='logo-badge']")).toHaveText("Icon · Saved");

  // Leave the seed as it was: clear the kit icon from the Icon tab's Kit choice card.
  await page.goto("/logos/welding_v2?type=icon");
  await page.locator("[data-test='kit-clear']").click();
  await page.waitForURL(/\/logos\/welding_v2/);
  await expect(page.locator("[data-test='kit-choice-saved']")).toContainText("No Icon saved yet");
});

test("with no kit icon saved, a brand's Navbar tab keeps its own Icon row picker", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 800 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/welding_v2?colouring=alt");
  await expect(page.locator("[data-test='edit-row'][data-part='icon'] [data-test='edit-swatch']").first()).toBeVisible();
  await expect(page.locator("[data-test='edit-kit-icon']")).toHaveCount(0);
  for (const p of await params(tabImages(page))) expect(p).not.toHaveProperty("icon_colouring");
  const bodyFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(bodyFits, "the page body does not scroll sideways at 375").toBe(true);
});
