// [e2e] The hub's assets, served by Propshaft, reach a live browser and apply
// (task hub-moves-to-propshaft). Sprockets is gone: no manifest.js, no require
// directives. A String test can see a fingerprinted <link>; only a browser can
// see that the stylesheet parsed into rules, that it styles the page, that every
// /assets request answered, and that the importmap's modules ran.
// @qa-readonly: it only reads signed-out public pages.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

test("the public pages load fingerprinted Propshaft assets that apply, at 390 and 1280", async ({ page }) => {
  test.setTimeout(60_000);
  await blockThirdPartyRequests(page);
  const badAssets = [];
  const pageErrors = [];
  page.on("response", (r) => { if (r.url().includes("/assets/") && r.status() >= 400) badAssets.push(`${r.status()} ${r.url()}`); });
  page.on("pageerror", (e) => pageErrors.push(e.message));

  for (const width of [390, 1280]) {
    await page.setViewportSize({ width, height: 900 });
    for (const path of ["/", "/about", "/packages"]) {
      await page.goto(path);
      const sheets = await page.evaluate(() =>
        [...document.styleSheets].filter((s) => s.href).map((s) => ({ name: new URL(s.href).pathname, rules: s.cssRules.length })));
      const tailwind = sheets.find((s) => /^\/assets\/tailwind-[0-9a-f]{8,}\.css$/.test(s.name));
      expect(tailwind, `${path} at ${width}: the tailwind build is linked fingerprinted`).toBeTruthy();
      expect(tailwind.rules, `${path} at ${width}: tailwind.css parsed into rules`).toBeGreaterThan(100);
      expect(sheets.some((s) => /^\/assets\/application-[0-9a-f]{8,}\.css$/.test(s.name)), "application.css is linked").toBe(true);

      // The stylesheet styles the page: the pinned header takes its rule from it.
      const position = await page.locator("header.nav-shell").first().evaluate((el) => getComputedStyle(el).position);
      expect(position, `${path} at ${width}: the header is styled`).not.toBe("static");

      // The importmap ran: Turbo, a pinned module, is live on the page.
      await expect.poll(() => page.evaluate(() => typeof window.Turbo), { message: `${path} Turbo loaded` }).toBe("object");
    }
  }

  // The dark-page kit icon swap (app/assets/tailwind/application.css) survives Propshaft.
  await page.goto("/signin");
  await page.evaluate(() => document.documentElement.classList.add("dark"));
  const swapped = await page.locator('img[src="/brand/icon-light.svg"]').first().evaluate((img) => getComputedStyle(img).content);
  expect(swapped).toContain("/brand/icon-dark.svg");

  expect(badAssets).toEqual([]);
  expect(pageErrors).toEqual([]);
});
