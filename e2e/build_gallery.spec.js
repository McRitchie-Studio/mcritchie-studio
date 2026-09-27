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

  // About 3.3 cards: one card is roughly 30% of the row.
  const ratio = await row.evaluate((el) => el.clientWidth / el.children[0].getBoundingClientRect().width);
  expect(ratio).toBeGreaterThan(3.1);
  expect(ratio).toBeLessThan(3.6);
  // Every card is the same width: a long host (prisoners-dilemma.mcritchie.studio)
  // truncates instead of widening its card.
  const widths = await row.evaluate((el) => [...el.children].map((li) => Math.round(li.getBoundingClientRect().width)));
  expect(new Set(widths).size).toBe(1);

  // Cyvasse, Prisoners Dilemma and Rantly lead (config/build_examples.yml `lead`).
  const hosts = await page.locator("[data-test='build-example']").evaluateAll((links) => links.map((a) => new URL(a.href).host.split(".")[0]));
  expect(hosts.slice(0, 3)).toEqual(["cyvasse", "prisoners-dilemma", "rantly"]);

  const image = page.locator("[data-test='build-example-image']").first();
  await image.scrollIntoViewIfNeeded();
  await expect.poll(() => image.evaluate((img) => img.complete && img.naturalWidth)).toBeGreaterThan(0);

  // At the start only the right edge fades; scrolled to the end, only the left.
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).maskImage)).toContain("calc(100% - 64px)");
  await row.evaluate((el) => el.scrollTo({ left: el.scrollWidth }));
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).maskImage)).not.toContain("calc(100% - 64px)");
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).maskImage)).toContain("48px");
});
