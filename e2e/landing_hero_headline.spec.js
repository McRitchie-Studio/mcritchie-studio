// [e2e] The landing hero's headline (task hero-says-built-right).
//
// Alex McRitchie, 2026-10-30: "Your ___ Built Right with the options [Workflow, Idea,
// Plan]"; 2026-11-03: the words are Idea, Workflow, Agent, at 3s each. The middle word cycles; at a phone, the lg edge and a desktop each word
// sits whole inside its box, centred, the headline never reaches the subtitle,
// the headline holds one height through the cycle (a word that fits where another
// wraps must not reflow the page), and the page never scrolls sideways. The word
// stays whole WHILE it drops in too: an earlier cut whose box fitted each word
// clipped "Workflow" to "Workflov" for its first 0.4s (Carl's review of PR #2352).
// The box is static now (Alex McRitchie: no expanding title), so it holds one
// width through the cycle as well.
// The first word starts in place, with no drop-in, and Your stands beside
// the word from 400px up (below it, Your stacks above a centred word). Side by side,
// the row centres on the median word, so Workflow hangs past the box but stays on screen.
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
  await expect(page.locator("h1.hero-title")).toContainText("Built Right");

  const seen = {};
  // Every frame of every entry, sampled in the page for the first 600ms after a
  // word goes active: its text never runs past either edge of the box.
  await page.evaluate(() => {
    window.__heroClips = [];
    const box = document.querySelector(".dropping-texts");
    new MutationObserver((records) => {
      for (const r of records) {
        if (!r.target.classList.contains("drop-active")) continue;
        const span = r.target;
        const start = performance.now();
        const sample = () => {
          const range = document.createRange();
          range.selectNodeContents(span);
          const text = range.getBoundingClientRect();
          const b = box.getBoundingClientRect();
          // Side by side, a long word may pass the box's right edge, not the screen's.
          const rightLimit = window.innerWidth >= 400 ? window.innerWidth : b.right;
          const over = Math.max(b.left - text.left, text.right - rightLimit);
          if (over > 1) window.__heroClips.push(`${span.textContent} ${Math.round(over)}px at ${Math.round(performance.now() - start)}ms`);
          if (performance.now() - start < 600) requestAnimationFrame(sample);
        };
        sample();
      }
    }).observe(box, { subtree: true, attributes: true, attributeFilter: ["class"] });
  });

  // Workflow, Agent, then Idea again; Idea starts in place, so its first entry is the
  // short-to-long one, the entry that once clipped.
  for (const word of ["Workflow", "Agent", "Idea"]) {
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
      const yourRange = document.createRange();
      yourRange.selectNodeContents(document.querySelector("h1.hero-title").firstElementChild);
      const your = yourRange.getBoundingClientRect();
      const subtitle = document.querySelector(".hero-subtitle").getBoundingClientRect();
      return {
        inside: text.left >= box.left - 1 && text.right <= (window.innerWidth >= 400 ? window.innerWidth : box.right) + 1,
        rowCentreOff: Math.abs((your.left + box.right) / 2 - (h1.left + h1.right) / 2),
        boxEm: box.width / parseFloat(getComputedStyle(document.querySelector("h1.hero-title")).fontSize),
        align: getComputedStyle(span).textAlign,
        besideYour: text.left >= your.right && Math.abs(text.bottom - your.bottom) <= 2,
        // Glyph boxes overlap at line-height 1.1, so compare against Your's middle.
        belowYour: text.top >= your.top + your.height / 2,
        h1Height: Math.round(h1.height),
        boxWidth: Math.round(box.width),
        clears: h1.bottom <= subtitle.top,
        sideways: document.documentElement.scrollWidth > window.innerWidth,
      };
    }, word);
  }

  for (const [word, m] of Object.entries(seen)) {
    expect(m.inside, `${word} sits whole inside its box`).toBe(true);
    const sideBySide = width >= 400;
    expect(m.align, `${word} is aligned`).toBe(sideBySide ? "left" : "center");
    if (sideBySide) {
      expect(m.besideYour, `${word} sits beside Your, on its baseline`).toBe(true);
      expect(m.rowCentreOff, `${word}: Your plus the box is centred`).toBeLessThanOrEqual(1);
      // With room to spare, the box is the median word's width, not Workflow's.
      if (width >= 1024) expect(m.boxEm, `${word}: the box is the median word`).toBeCloseTo(3.15, 1);
    }
    else expect(m.belowYour, `${word} sits below Your`).toBe(true);
    expect(m.clears, `${word}: the headline clears the subtitle`).toBe(true);
    expect(m.sideways, `${word}: no sideways scroll`).toBe(false);
  }
  // Let the last entry's 600ms of samples finish.
  await page.waitForTimeout(100);
  expect(await page.evaluate(() => window.__heroClips), "no word is clipped while it drops in").toEqual([]);
  const widths = new Set(Object.values(seen).map((m) => m.boxWidth));
  expect([...widths], "the word's box holds one width through the cycle").toHaveLength(1);
  const heights = new Set(Object.values(seen).map((m) => m.h1Height));
  expect([...heights], "the headline holds one height through the cycle").toHaveLength(1);
  // The call to action holds one line at every width: 24px text, 36px line, 1rem padding.
  const cta = await page.locator("[data-test='hero-build-cta']").boundingBox();
  expect(cta.height, "Build Your Website holds one line").toBeLessThanOrEqual(70);
  expect(cta.x + cta.width, "Build Your Website stays on screen").toBeLessThanOrEqual(width);

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
