// [e2e] The landing hero's headline: Your [Idea, Flow, Agent, Plan] Built for 2027, 3s a word.
// The first word starts in place, with no drop-in. Your stands beside the word at every
// width, and the row centres on the median word's box, which never moves or resizes.
// Each word starts at the box's left edge; Agent hangs past its right edge but stays on
// screen, on every frame of its entry. The headline clears the subtitle, holds one
// height, and the page never scrolls sideways.
// @qa-readonly: it only reads the signed-out landing page.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, watchPageErrors, VISITOR } = require("./helpers");
const { animationsSettled } = require("./settle");

test.use({ storageState: VISITOR });
test.setTimeout(45_000);

// Each width is its own bare test(): the e2e census counts bare declarations.
async function checkHeadline(page, width) {
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  await page.setViewportSize({ width, height: 800 });
  // Every transition a word starts, from before the page's first script runs.
  await page.addInitScript(() => {
    window.__heroRuns = [];
    document.addEventListener("transitionrun", (e) => {
      if (!e.target.parentElement?.classList.contains("dropping-texts")) return;
      window.__heroRuns.push({ text: e.target.textContent, exit: e.target.classList.contains("drop-exit") });
    });
  });
  await page.goto("/");
  await page.evaluate(() => document.fonts.ready);
  await expect(page.locator("h1.hero-title")).toContainText("Built for 2027");

  const seen = {};
  // Every frame of every entry, sampled in the page for the first 600ms after a
  // word goes active: its text never runs past either edge of the box.
  await page.evaluate(() => {
    window.__heroClips = [];
    window.__heroSampling = 0; // entries still being sampled
    const box = document.querySelector(".dropping-texts");
    new MutationObserver((records) => {
      for (const r of records) {
        if (!r.target.classList.contains("drop-active")) continue;
        const span = r.target;
        const start = performance.now();
        window.__heroSampling += 1;
        const sample = () => {
          const range = document.createRange();
          range.selectNodeContents(span);
          const text = range.getBoundingClientRect();
          const b = box.getBoundingClientRect();
          // A long word may pass the box's right edge, not the screen's.
          const over = Math.max(b.left - text.left, text.right - window.innerWidth);
          if (over > 1) window.__heroClips.push(`${span.textContent} ${Math.round(over)}px at ${Math.round(performance.now() - start)}ms`);
          if (performance.now() - start < 600) requestAnimationFrame(sample);
          else window.__heroSampling -= 1;
        };
        sample();
      }
    }).observe(box, { subtree: true, attributes: true, attributeFilter: ["class"] });
  });

  // Round the cycle, back to Idea: it starts in place, so this is its first entry.
  for (const word of ["Flow", "Agent", "Plan", "Idea"]) {
    const active = page.locator(".dropping-texts > span.drop-active", { hasText: word });
    await expect(active).toHaveCount(1, { timeout: 8_000 });
    // Measured once the word has landed: its drop-in (and the last word's exit) are done.
    await animationsSettled(page, ".dropping-texts");
    seen[word] = await page.evaluate((w) => {
      const box = document.querySelector(".dropping-texts").getBoundingClientRect();
      const span = [...document.querySelectorAll(".dropping-texts > span")].find((s) => s.textContent === w);
      const range = document.createRange();
      range.selectNodeContents(span);
      const text = range.getBoundingClientRect();
      const h1 = document.querySelector("h1.hero-title").getBoundingClientRect();
      const yourRange = document.createRange();
      yourRange.selectNodeContents(document.querySelector("h1.hero-title").firstElementChild);
      const your = yourRange.getBoundingClientRect();
      const subtitle = document.querySelector(".hero-subtitle").getBoundingClientRect();
      return {
        inside: text.left >= box.left - 1 && text.right <= window.innerWidth + 1,
        rowCentreOff: Math.abs((your.left + box.right) / 2 - (h1.left + h1.right) / 2),
        align: getComputedStyle(span).textAlign,
        besideYour: text.left >= your.right && Math.abs(text.bottom - your.bottom) <= 2,
        h1Height: Math.round(h1.height),
        h1Lines: Math.round(h1.height / (parseFloat(getComputedStyle(document.querySelector("h1.hero-title")).fontSize) * 1.1)),
        boxWidth: Math.round(box.width),
        clears: h1.bottom <= subtitle.top,
        sideways: document.documentElement.scrollWidth > window.innerWidth,
      };
    }, word);
  }

  for (const [word, m] of Object.entries(seen)) {
    expect(m.inside, `${word} sits whole inside its box`).toBe(true);
    expect(m.align, `${word} starts at the box's left edge`).toBe("left");
    expect(m.besideYour, `${word} sits beside Your, on its baseline`).toBe(true);
    expect(m.rowCentreOff, `${word}: Your plus the box is centred`).toBeLessThanOrEqual(1);
    // Built for 2027 needs 357px at the type scale's heading size.
    if (width >= 375) expect(m.h1Lines, `${word}: the headline is two lines`).toBe(2);
    expect(m.clears, `${word}: the headline clears the subtitle`).toBe(true);
    expect(m.sideways, `${word}: no sideways scroll`).toBe(false);
  }
  // Let the last entry's 600ms of samples finish.
  await page.waitForFunction(() => window.__heroSampling === 0);
  expect(await page.evaluate(() => window.__heroClips), "no word is clipped while it drops in").toEqual([]);
  const widths = new Set(Object.values(seen).map((m) => m.boxWidth));
  expect([...widths], "the word's box holds one width through the cycle").toHaveLength(1);
  const heights = new Set(Object.values(seen).map((m) => m.h1Height));
  expect([...heights], "the headline holds one height through the cycle").toHaveLength(1);
  // The call to action holds one line at every width: 24px text, 36px line, 1rem padding.
  const cta = await page.locator("[data-test='hero-build-cta']").boundingBox();
  expect(cta.height, "Launch Your Website holds one line").toBeLessThanOrEqual(70);
  expect(cta.x, "Launch Your Website stays on screen, left").toBeGreaterThanOrEqual(0);
  expect(cta.x + cta.width, "Launch Your Website stays on screen, right").toBeLessThanOrEqual(width);

  // The first transition any word runs is Idea leaving: it never dropped in.
  const runs = await page.evaluate(() => window.__heroRuns);
  expect(runs[0], "the first move is out of Idea").toEqual({ text: "Idea", exit: true });
  expect(pageErrors, report()).toEqual([]);
}

test("at 320px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 320));
test("at 375px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 375));
test("at 400px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 400));
test("at 768px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 768));
test("at 1024px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 1024));
test("at 1280px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 1280));
