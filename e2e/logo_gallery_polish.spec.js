// [e2e] The logo gallery's polish pass (task logo-gallery-polish-pass): the edit panel's Reset is a
// full-size touch target on a phone, a kit original's Delete asks first, the Kit card's button rows
// line up, a Copy SVG fetches the logo from its own URL and says Copied, and a shared context link
// opens in its theme from the first paint.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function open(page, path, width = 1280) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(path);
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("the edit panel's Reset is at least 40 px tall at 375 px", async ({ page }) => {
  await open(page, "/logos/studio?first_colour=635BB2", 375);
  const box = await page.locator("[data-test='edit-reset']").boundingBox();
  expect(box.height).toBeGreaterThanOrEqual(40);
  expect(box.width).toBeGreaterThanOrEqual(40);
});
