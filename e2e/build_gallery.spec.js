// [e2e] /build — the "Built with McRitchie Studio" gallery, as a visitor sees it.
//
// e2e/seed.rb seeds three LIVE showcase apps (plus Cyvasse from
// config/build_examples.yml). What only a browser proves: the row really scrolls
// sideways, a screenshot really loads, and the edge fade follows the scroll.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests } = require("./helpers");

test("the gallery scrolls sideways, its screenshot loads, and the fade follows the scroll", async ({ page }) => {
  await blockThirdPartyRequests(page);
  await page.setViewportSize({ width: 1280, height: 1000 });
  await page.goto("/build");

  const row = page.locator("[data-test='build-gallery-row']");
  await expect(row).toBeVisible();
  await expect(page.locator("[data-test='build-gallery-item']")).toHaveCount(4);
  await expect(page.locator("[data-test='build-gallery-all']")).toHaveCount(0); // visitors see no admin button

  // 2.5 cards: one card is roughly 40% of the row.
  const ratio = await row.evaluate((el) => el.clientWidth / el.children[0].getBoundingClientRect().width);
  expect(ratio).toBeGreaterThan(2.3);
  expect(ratio).toBeLessThan(2.8);

  const image = page.locator("[data-test='build-example-image']").first();
  await image.scrollIntoViewIfNeeded();
  await expect.poll(() => image.evaluate((img) => img.complete && img.naturalWidth)).toBeGreaterThan(0);

  // At the start only the right edge fades; scrolled to the end, only the left.
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).maskImage)).toContain("calc(100% - 64px)");
  await row.evaluate((el) => el.scrollTo({ left: el.scrollWidth }));
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).maskImage)).not.toContain("calc(100% - 64px)");
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).maskImage)).toContain("48px");
});
