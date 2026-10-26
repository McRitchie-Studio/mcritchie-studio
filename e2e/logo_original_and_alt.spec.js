// [e2e] Logo colourings and kit defaults (task logo-original-and-alt): the Colouring control
// switches every logo on a tab, and its download, between the brand's Original and Alt;
// Studio, which has no original, offers Alt only and says so; and a saved kit choice is the
// tab's default (Alex McRitchie, 13:11: "The goal of the logo modification is to set the defaults").
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const images = (page) => page.locator("img[data-test='logo-image']");
const downloads = (page) => page.locator("a[data-test='logo-download']");

async function attrs(locator, name) {
  return locator.evaluateAll((els, attr) => els.map((el) => el.getAttribute(attr)), name);
}

async function loaded(page) {
  await page.waitForFunction(() =>
    [...document.querySelectorAll("img[data-test='logo-image']")].every((img) => img.complete && img.naturalWidth > 0)
  );
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("switching to Original changes every logo and its download, and Alt changes them back", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/welding?type=stacked&colouring=alt");
  await loaded(page);
  for (const src of await attrs(images(page), "src")) expect(src).not.toContain("colouring=");
  for (const href of await attrs(downloads(page), "href")) expect(href).not.toContain("colouring=");

  await page.locator("a[data-test='colouring-option'][data-colouring='original']").click();
  await expect(page.locator("a[data-test='colouring-option'][aria-current='true']")).toHaveText("Original");
  await loaded(page);
  const srcs = await attrs(images(page), "src");
  expect(srcs.length).toBe(2);
  for (const src of srcs) expect(src).toContain("colouring=original");
  for (const href of await attrs(downloads(page), "href")) expect(href).toContain("colouring=original");
  for (const alt of await attrs(images(page), "alt")) expect(alt).toContain("original colouring");
  // The word rows work in Original (task logo-compare-and-original-edits); only the icon's colour needs Alt.
  await expect(page.locator("[data-test='edit-row'][data-part='first']")).toBeVisible();
  await expect(page.locator("[data-test='edit-icon-original']")).toContainText("its colour changes in Alt only");

  await page.locator("a[data-test='colouring-option'][data-colouring='alt']").click();
  await expect(page.locator("a[data-test='colouring-option'][aria-current='true']")).toHaveText("Alt");
  await loaded(page);
  for (const src of await attrs(images(page), "src")) expect(src).not.toContain("colouring=");
});

test("Studio offers Alt only and says it has no original", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 800 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/studio");
  await expect(page.locator("[data-test='no-original']")).toHaveText("McRitchie Studio's logo is solid colour, so it has no separate original.");
  await expect(page.locator("[data-test='colouring-option'][data-colouring='original']")).toHaveAttribute("aria-disabled", "true");
  const bodyFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(bodyFits, "the page body does not scroll sideways at 375").toBe(true);
});

test("Save as default on Commercial Welding's With tagline, then the bare Stacked tab opens on it", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/welding?type=stacked&form=tagline");
  await page.locator("[data-test='logo-controls'] [data-test='kit-save-default']").click();
  await page.waitForURL(/\/logos\/welding\?type=stacked$/);
  await page.goto("/logos/welding?type=stacked");
  await expect(page.locator("a[data-test='form-option'][aria-current='true']")).toHaveText("With tagline");
  await expect(page.locator("[data-test='kit-default-state']")).toHaveText("Showing the kit default.");
  await page.locator("a[data-test='form-option'][data-form='two_line']").click();
  await expect(page.locator("[data-test='kit-default-state']")).toContainText("Changed from the kit default");
  await page.locator("[data-test='kit-default-back']").click();
  await expect(page.locator("a[data-test='form-option'][aria-current='true']")).toHaveText("With tagline");
  // Leave the seed as it was: clear the saved choice.
  await page.locator("[data-test='kit-clear']").click();
  await page.waitForURL(/\/logos\/welding/);
  await page.goto("/logos/welding?type=stacked");
  await expect(page.locator("a[data-test='form-option'][aria-current='true']")).toHaveText("Two lines");
});
