// [e2e] The landing hero's headline (task hero-says-built-right).
//
// Alex McRitchie, 2026-10-30: "Your ___ Built Right with the options [Workflow, Idea,
// Plan]". The middle word cycles; at a phone, the lg edge and a desktop each word
// sits whole inside its box, centred, the headline never reaches the subtitle,
// the headline holds one height through the cycle (a word that fits where another
// wraps must not reflow the page), and the page never scrolls sideways.
// @qa-readonly: it only reads the signed-out landing page.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });
test.setTimeout(45_000);

// Each width is its own bare test(): the e2e census counts bare declarations.
async function checkHeadline(page, width) {
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  await page.setViewportSize({ width, height: 800 });
  await page.goto("/");
  await page.evaluate(() => document.fonts.ready);
  await expect(page.locator("h1.hero-title")).toContainText("Built Right");

  const seen = {};
  for (const word of ["Workflow", "Idea", "Plan"]) {
    const active = page.locator(".dropping-texts > span.drop-active", { hasText: word });
    await expect(active).toHaveCount(1, { timeout: 8_000 });
    // The box eases to the word's width (0.4s) after it drops in.
    await page.waitForTimeout(600);
    seen[word] = await page.evaluate((w) => {
      const box = document.querySelector(".dropping-texts").getBoundingClientRect();
      const span = [...document.querySelectorAll(".dropping-texts > span")].find((s) => s.textContent === w);
      const range = document.createRange();
      range.selectNodeContents(span);
      const text = range.getBoundingClientRect();
      const h1 = document.querySelector("h1.hero-title").getBoundingClientRect();
      const subtitle = document.querySelector(".hero-subtitle").getBoundingClientRect();
      return {
        inside: text.left >= box.left - 1 && text.right <= box.right + 1,
        align: getComputedStyle(span).textAlign,
        h1Height: Math.round(h1.height),
        clears: h1.bottom <= subtitle.top,
        sideways: document.documentElement.scrollWidth > window.innerWidth,
      };
    }, word);
  }

  for (const [word, m] of Object.entries(seen)) {
    expect(m.inside, `${word} sits whole inside its box`).toBe(true);
    expect(m.align, `${word} is centred`).toBe("center");
    expect(m.clears, `${word}: the headline clears the subtitle`).toBe(true);
    expect(m.sideways, `${word}: no sideways scroll`).toBe(false);
  }
  const heights = new Set(Object.values(seen).map((m) => m.h1Height));
  expect([...heights], "the headline holds one height through the cycle").toHaveLength(1);
  expect(pageErrors, report()).toEqual([]);
}

test("at 320px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 320));
test("at 375px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 375));
test("at 1024px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 1024));
test("at 1280px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 1280));
