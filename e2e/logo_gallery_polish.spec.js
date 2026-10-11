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

test("deleting a kit original asks first: Delete opens the question, Cancel closes it, and the named button deletes", async ({ page }) => {
  await open(page, "/logos/turf?type=icon");
  const card = page.locator("[data-test='kit-originals']");
  await card.locator("input[type='file']").setInputFiles([
    { name: "turf-polish.svg", mimeType: "image/svg+xml", buffer: Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>') }
  ]);
  await card.locator("[data-test='kit-original-upload']").click();
  await page.waitForURL(/#kit-originals/);
  const item = page.locator("[data-test='kit-original']").filter({ hasText: "turf-polish.svg" });
  const confirm = item.locator("[data-test='kit-original-delete-confirm']");
  await expect(confirm).toBeHidden();

  // By keyboard: the first step is a focusable control, and Enter opens it.
  await item.locator("[data-test='kit-original-delete']").focus();
  await page.keyboard.press("Enter");
  await expect(confirm).toBeVisible();
  await expect(confirm).toHaveText("Delete turf-polish.svg");
  await expect(item.locator("[data-test='kit-original-delete']")).toContainText("Cancel");
  await page.keyboard.press("Enter");
  await expect(confirm).toBeHidden();
  await expect(item).toHaveCount(1);

  await item.locator("[data-test='kit-original-delete']").click();
  await confirm.click();
  await expect(page.getByText("Removed turf-polish.svg.")).toBeVisible();
  await expect(page.locator("[data-test='kit-original']").filter({ hasText: "turf-polish.svg" })).toHaveCount(0);
});
