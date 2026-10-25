// [e2e] Every visitor gets lang, one main, and a hero sized to the phone
// (task hub-every-visitor-lang-main-hero; lane-ui-infrastructure P1 and P2).
//
// axe-core (the engine the nightly UI budget runs, bin/lib/ui_budget/collect.cjs)
// checks the document shell on the three public pages at desktop and phone
// widths: html-has-lang, landmark-one-main, and region (no content outside a
// landmark). Then the home page at 390px must fetch no image over 300 KB: the
// hero was one 1.6MB 4700px AVIF on every phone.
// @qa-readonly: it only reads signed-out public pages.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

const AXE_PATH = require.resolve("axe-core/axe.min.js");
const SHELL_RULES = ["html-has-lang", "landmark-one-main", "region"];

for (const path of ["/", "/packages", "/about"]) {
  test(`${path} passes axe's lang and landmark rules at 1280 and 390`, async ({ page }) => {
    test.setTimeout(45_000);
    await blockThirdPartyRequests(page);
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto(path);
      await expect(page.locator("html")).toHaveAttribute("lang", "en");
      await expect(page.locator("main")).toHaveCount(1);
      await page.addScriptTag({ path: AXE_PATH });
      const violations = await page.evaluate(async (rules) => {
        const result = await window.axe.run(document, { resultTypes: ["violations"], runOnly: { type: "rule", values: rules } });
        return result.violations.map((v) => ({ id: v.id, impact: v.impact, targets: v.nodes.slice(0, 5).map((n) => n.target.join(" ")) }));
      }, SHELL_RULES);
      expect(violations, `${path} at ${width}px`).toEqual([]);
    }
  });
}

test("the home page at 390px requests no image over 300 KB, and the hero is the phone crop", async ({ page }) => {
  test.setTimeout(45_000);
  await blockThirdPartyRequests(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/", { waitUntil: "load" });

  // Resource Timing, read after load: every image the page fetched, with its
  // body size (same-origin, so encodedBodySize is reported).
  const images = await page.evaluate(() => performance.getEntriesByType("resource")
    .filter((e) => e.initiatorType === "img" || /\.(avif|webp|png|jpe?g|gif)(\?|$)/i.test(e.name))
    .map((e) => ({ url: e.name, bytes: e.encodedBodySize })));
  expect(images.length, "the page fetched images").toBeGreaterThan(0);
  const heavy = images.filter((i) => i.bytes > 300 * 1024);
  expect(heavy, "images over 300 KB at 390px").toEqual([]);

  const hero = page.locator("img[data-hero-image]");
  await expect(hero).toHaveCount(1);
  const heroSrc = await hero.evaluate((img) => img.currentSrc);
  expect(heroSrc, "a phone takes the portrait crop, not the panorama").toMatch(/\/assets\/hero\/denver-hero-portrait-\d+-[0-9a-f]+\.avif$/);
  expect(images.map((i) => i.url), "the hero was fetched and measured").toContain(heroSrc);

  // The pan still runs on the sized image.
  expect(await hero.evaluate((img) => getComputedStyle(img).animationName)).toBe("hero-pan");
});

// A real 390px phone has a device scale of 2 or 3, so it asks for the 768 or
// 1260 candidate, not the 390 one Playwright's default (1) fetches. Every
// candidate a phone can choose must stay under 300 KB too.
test("a 390px phone at device scale 3 still fetches no image over 300 KB", async ({ browser }) => {
  test.setTimeout(45_000);
  const context = await browser.newContext({ storageState: VISITOR, viewport: { width: 390, height: 844 }, deviceScaleFactor: 3 });
  const page = await context.newPage();
  try {
    await blockThirdPartyRequests(page);
    await page.goto("/", { waitUntil: "load" });
    const images = await page.evaluate(() => performance.getEntriesByType("resource")
      .filter((e) => e.initiatorType === "img" || /\.(avif|webp|png|jpe?g|gif)(\?|$)/i.test(e.name))
      .map((e) => ({ url: e.name, bytes: e.encodedBodySize })));
    const heroSrc = await page.locator("img[data-hero-image]").evaluate((img) => img.currentSrc);
    expect(heroSrc, "scale 3 takes the largest portrait crop").toMatch(/denver-hero-portrait-1260-[0-9a-f]+\.avif$/);
    expect(images.filter((i) => i.bytes > 300 * 1024), "images over 300 KB at 390px, scale 3").toEqual([]);
  } finally {
    await context.close();
  }
});
