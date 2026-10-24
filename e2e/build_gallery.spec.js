// [e2e] /build — the "Built with McRitchie Studio" gallery, as a visitor sees it.
//
// e2e/seed.rb seeds three LIVE showcase apps (plus Cyvasse and Turf Monster
// from config/build_examples.yml). What only a browser proves: the row really scrolls
// sideways, a still really loads, the edge fade follows the scroll, and a card's
// motion loop plays on hover (and not under reduced motion).
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, VISITOR } = require("./helpers");

// What a visitor sees: signed out, not the suite's default admin session.
test.use({ storageState: VISITOR });

test("the gallery scrolls sideways, its still loads, and the fade follows the scroll", async ({ page }) => {
  await blockThirdPartyRequests(page);
  await page.setViewportSize({ width: 1280, height: 1000 });
  await page.goto("/build");

  const row = page.locator("[data-test='build-gallery-row']");
  await expect(row).toBeVisible();
  await expect(page.locator("[data-test='build-gallery-item']")).toHaveCount(5);
  await expect(page.locator("[data-test='build-gallery-all']")).toHaveCount(0); // visitors see no admin button

  // About 3.3 cards: one card is roughly 30% of the row.
  const ratio = await row.evaluate((el) => el.clientWidth / el.children[0].getBoundingClientRect().width);
  expect(ratio).toBeGreaterThan(3.1);
  expect(ratio).toBeLessThan(3.6);
  // Every card is the same width: a long host (prisoners-dilemma.mcritchie.studio)
  // truncates instead of widening its card.
  const widths = await row.evaluate((el) => [...el.children].map((li) => Math.round(li.getBoundingClientRect().width)));
  expect(new Set(widths).size).toBe(1);

  // Cyvasse, Turf Monster, Prisoners Dilemma and Rantly lead
  // (config/build_examples.yml `lead`); the first two on their own domains.
  const hosts = await page.locator("[data-test='build-example']").evaluateAll((links) => links.map((a) => new URL(a.href).host));
  expect(hosts.slice(0, 4)).toEqual(["cyvasse.xyz", "turfmonster.media", "prisoners-dilemma.mcritchie.studio", "rantly.mcritchie.studio"]);

  // The description is one line, cut with an ellipsis. Measured, not read off
  // the class: fill one with far more than a line of text and it must still
  // render one line tall.
  const lines = await page.locator("[data-test='build-example-blurb']").first().evaluate((el) => {
    el.textContent = "A long description that keeps going. ".repeat(20);
    return el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight);
  });
  expect(lines).toBeLessThanOrEqual(1.05);

  const image = page.locator("[data-test='build-example-image']").first();
  await image.scrollIntoViewIfNeeded();
  await expect.poll(() => image.evaluate((img) => img.complete && img.naturalWidth)).toBeGreaterThan(0);

  // At the start only the right edge fades; scrolled to the end, only the left.
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).maskImage)).toContain("calc(100% - 64px)");
  await row.evaluate((el) => el.scrollTo({ left: el.scrollWidth }));
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).maskImage)).not.toContain("calc(100% - 64px)");
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).maskImage)).toContain("48px");
});

// Each showcase app has a dark still and a short loop (build_gallery/<sub>.webp
// and .mp4). The loop loads nothing until a mouse rests on the card, then plays
// over the still; leaving stops it. Under reduced motion the still stays.
test("a card plays its motion loop on hover, and keeps the still under reduced motion", async ({ page }) => {
  await blockThirdPartyRequests(page);
  // The suite runs under reduced motion (playwright.config.js); a visitor who
  // has not asked for it is the case under test first.
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.setViewportSize({ width: 1280, height: 1000 });
  await page.goto("/build");

  const card = page.locator("[data-test='build-example']").first();
  const video = card.locator("[data-test='build-example-motion']");
  await card.scrollIntoViewIfNeeded();
  expect(await video.evaluate((v) => v.paused)).toBe(true);
  expect(await video.evaluate((v) => getComputedStyle(v).opacity)).toBe("0");

  await card.hover();
  await expect.poll(() => video.evaluate((v) => !v.paused && v.currentTime > 0)).toBe(true);
  await expect.poll(() => video.evaluate((v) => getComputedStyle(v).opacity)).toBe("1");

  await page.mouse.move(0, 0);
  await expect.poll(() => video.evaluate((v) => v.paused)).toBe(true);

  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.reload();
  const calmCard = page.locator("[data-test='build-example']").first();
  const calmVideo = calmCard.locator("[data-test='build-example-motion']");
  await calmCard.scrollIntoViewIfNeeded();
  await calmCard.hover();
  await page.waitForTimeout(600);
  expect(await calmVideo.evaluate((v) => v.paused)).toBe(true);
  expect(await calmVideo.evaluate((v) => getComputedStyle(v).display)).toBe("none");
});
