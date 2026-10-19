// [e2e] The landing hero's Build Your App (task landing-build-ctas).
//
// Alex, 2026-10-19: "Build Your App with a rainbow glow to draw the eyes." The
// hero CTA wears the cta-glow primitive's rainbow preset. On a 375px phone the
// glow never scrolls the page sideways at any point of its motion; under reduced
// motion the glow holds still; and the CTA goes to /build.
// @qa-readonly: it only reads the signed-out landing page.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

const glowSelector = "[data-test='hero-build-glow']";

test("on a phone the rainbow Build Your App never scrolls the page sideways, in either theme", async ({ page }) => {
  test.setTimeout(45_000);
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  await page.setViewportSize({ width: 375, height: 760 });
  await page.emulateMedia({ reducedMotion: "no-preference" });
  for (const scheme of ["light", "dark"]) {
    await page.emulateMedia({ colorScheme: scheme });
    await page.goto("/");
    const glow = page.locator(glowSelector);
    await expect(glow).toBeVisible();
    const cta = glow.getByRole("link", { name: "Build Your App" });
    await expect(cta).toHaveAttribute("href", "/build");
    const layer = await glow.evaluate((el) => {
      const after = getComputedStyle(el, "::after");
      return { animation: after.animationName, background: getComputedStyle(el, "::before").backgroundImage };
    });
    expect(layer.animation, "the glow is moving").toBe("cta-glow-trade");
    expect(layer.background, "the glow is the rainbow's seven stops, not the three-colour default").toMatch(/conic-gradient/);
    expect((layer.background.match(/rgb\(/g) || []).length, "rainbow stops").toBeGreaterThanOrEqual(7);
    // Sample across one whole cycle of the motion (3s each way).
    let worst = 0;
    for (let i = 0; i < 14; i += 1) {
      worst = Math.max(worst, await page.evaluate(() => document.scrollingElement.scrollWidth - window.innerWidth));
      await page.waitForTimeout(250);
    }
    expect(worst, `${scheme}: the page never scrolls sideways`).toBeLessThanOrEqual(0);
  }
  await expect(page.locator("[data-test='hero-meet-alex']")).toHaveAttribute("href", "#about");
  expect(pageErrors, report()).toHaveLength(0);
});

test("under reduced motion the hero glow holds still", async ({ page }) => {
  await blockThirdPartyRequests(page);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");
  const glow = page.locator(glowSelector);
  await expect(glow).toBeVisible();
  expect(await glow.evaluate((el) => getComputedStyle(el, "::after").animationName)).toBe("none");
});
