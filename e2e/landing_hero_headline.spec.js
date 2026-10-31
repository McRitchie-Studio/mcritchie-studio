// [e2e] The landing hero's headline (task hero-says-built-right).
//
// Alex McRitchie, 2026-10-30: "Your ___ Built Right with the options [Workflow, Idea,
// Plan]". The middle word cycles; at a phone, the lg edge and a desktop each word
// sits whole inside its box, centred, the headline never reaches the subtitle,
// the headline holds one height through the cycle (a word that fits where another
// wraps must not reflow the page), and the page never scrolls sideways. The word
// stays whole WHILE it drops in too: an earlier cut whose box fitted each word
// clipped "Workflow" to "Workflov" for its first 0.4s (Carl's review of PR #2352).
// The box is static now (Alex McRitchie: no expanding title), so it holds one
// width through the cycle as well.
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
          const over = Math.max(b.left - text.left, text.right - b.right);
          if (over > 1) window.__heroClips.push(`${span.textContent} ${Math.round(over)}px at ${Math.round(performance.now() - start)}ms`);
          if (performance.now() - start < 600) requestAnimationFrame(sample);
        };
        sample();
      }
    }).observe(box, { subtree: true, attributes: true, attributeFilter: ["class"] });
  });

  // Idea, Plan, then Workflow again: the short-to-long entry is the one that clipped.
  for (const word of ["Idea", "Plan", "Workflow"]) {
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
        boxWidth: Math.round(box.width),
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
  // Let the last entry's 600ms of samples finish.
  await page.waitForTimeout(100);
  expect(await page.evaluate(() => window.__heroClips), "no word is clipped while it drops in").toEqual([]);
  const widths = new Set(Object.values(seen).map((m) => m.boxWidth));
  expect([...widths], "the word's box holds one width through the cycle").toHaveLength(1);
  const heights = new Set(Object.values(seen).map((m) => m.h1Height));
  expect([...heights], "the headline holds one height through the cycle").toHaveLength(1);
  expect(pageErrors, report()).toEqual([]);
}

test("at 320px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 320));
test("at 375px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 375));
test("at 768px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 768));
test("at 1024px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 1024));
test("at 1280px every headline word fits its box and clears the subtitle", async ({ page }) => checkHeadline(page, 1280));
