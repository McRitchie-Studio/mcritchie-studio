// [e2e] /websites portfolio cards (Alex McRitchie, 2026-11-08): the app's still is the whole
// card, the open card wears a violet ring, and ONE caption under the stack carries the open
// app's name (its h2), host and blurb. The caption sits in one fixed place and cross-fades as the
// row moves: the leaving one out, then the arriving one in, never two at once. Only a browser
// resolves which caption shows, where, and the colours a visitor sees, so all are measured here.
// Every check holds on the cascade and on the spotlight.
const { test, expect, devices } = require("@playwright/test");
const { blockThirdPartyRequests, VISITOR, watchPageErrors } = require("./helpers");

test.use({ storageState: VISITOR });

// WCAG contrast of two [r, g, b] colours (0-255).
function contrast(a, b) {
  const lum = (rgb) => {
    const [r, g, bl] = rgb.map((c) => { const v = c / 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// "rgb(26, 21, 53)" or "rgba(26, 21, 53, 0.92)" or "rgb(26 21 53 / 0.92)" to [r, g, b, a].
function parse(colour) {
  const parts = colour.match(/[\d.]+/g).map(Number);
  return [parts[0], parts[1], parts[2], parts.length > 3 ? parts[3] : 1];
}

const STAGE = "[data-portfolio-stage]";
const ROW = "[data-test='websites-carousel']";
const CAPTIONS = `${STAGE} [data-portfolio-captions] [data-test='portfolio-caption']`;
const OPEN_CAPTION = `${CAPTIONS}[data-current]`;
const OPEN_CARD = `${ROW} .carousel-slide[data-current]:not([aria-hidden='true']) [data-portfolio-card]`;

// The names on the captions a visitor can see.
const shownCaptions = (page) => page.locator(CAPTIONS).evaluateAll((all) =>
  all.filter((caption) => getComputedStyle(caption).visibility !== "hidden" && Number(getComputedStyle(caption).opacity) > 0.02)
    .map((caption) => caption.querySelector("[data-test='build-example-name']").textContent.trim()));

// The level-2 headings the accessibility tree holds under the stack.
const stageHeadings = async (page) => (await page.locator(STAGE).ariaSnapshot()).split("\n")
  .map((line) => line.match(/heading "(.*)" \[level=2\]/)).filter(Boolean).map((match) => match[1]);

// The first opaque background colour behind an element, else the page's.
const backdropOf = (locator) => locator.evaluate((element) => {
  for (let node = element; node; node = node.parentElement) {
    const parts = getComputedStyle(node).backgroundColor.match(/[\d.]+/g).map(Number);
    if (parts.length === 3 || parts[3] === 1) return getComputedStyle(node).backgroundColor;
  }
  return getComputedStyle(document.documentElement).backgroundColor;
});

const ring = (page, selector) => page.locator(selector).first().evaluate((card) => getComputedStyle(card).boxShadow);

async function openPage(browser, options, scheme = "dark") {
  const context = await browser.newContext({ storageState: VISITOR, ...options });
  const page = await context.newPage();
  const errors = watchPageErrors(page);
  await blockThirdPartyRequests(page);
  await page.goto("/websites");
  // The hub's theme is the dark class on <html>, not the browser's scheme.
  await page.evaluate((dark) => document.documentElement.classList.toggle("dark", dark), scheme === "dark");
  await expect(page.locator(ROW)).toHaveAttribute("data-carousel-ready", "");
  return { context, page, errors };
}

// In one hub theme; each theme is its own bare test below.
async function measureCards(browser, scheme) {
  // Full motion (the config's default context reduces it), so the cross-fade is really measured.
  const { context, page, errors } = await openPage(browser, { viewport: { width: 1400, height: 900 }, reducedMotion: "no-preference" }, scheme);
  expect(await page.evaluate(() => window.matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(false);
  expect(await page.evaluate(() => window.innerWidth)).toBe(1400);

  // Every card is the still alone, filling it, named for its app.
  const cards = page.locator(`${ROW} .carousel-slide:not([aria-hidden='true']) [data-portfolio-card]`);
  expect(await cards.count(), "Cyvasse, Turf Monster and at least two more").toBeGreaterThanOrEqual(4);
  const measured = await cards.evaluateAll((all) => all.map((card) => {
    const image = card.querySelector("[data-test='build-example-image']");
    const box = card.getBoundingClientRect();
    const pic = image && image.getBoundingClientRect();
    return {
      name: card.getAttribute("aria-label"),
      // A live showcase app without a still yet (the e2e seed's trivia-night) shows its emoji.
      fills: pic ? Math.abs(pic.width - box.width) < 1 && Math.abs(pic.height - box.height) < 1 : null,
      words: card.querySelector("[data-test='build-example-name'], [data-test='build-example-blurb']") !== null,
    };
  }));
  expect(measured.filter((card) => card.fills).length, "at least four apps show a still").toBeGreaterThanOrEqual(4);
  for (const card of measured) {
    expect(card.fills, `${card.name}: a still fills the whole card`).not.toBe(false);
    expect(card.words, `${card.name}: nothing is written over the still`).toBe(false);
  }

  // One caption, the open app's, its name the stack's one h2, under the page's one h1.
  const opened = await page.locator(OPEN_CARD).getAttribute("aria-label");
  await expect.poll(() => shownCaptions(page)).toEqual([opened]);
  await expect.poll(() => stageHeadings(page)).toEqual([opened]);
  expect(await page.getByRole("heading", { level: 1 }).allTextContents()).toEqual(["Portfolio"]);

  // It reads at 4.5:1 on the page behind it, with room under the card and between host and blurb.
  const caption = page.locator(OPEN_CAPTION);
  const backdrop = parse(await backdropOf(caption)).slice(0, 3);
  for (const hook of ["build-example-name", "build-example-host", "build-example-blurb"]) {
    const colour = await caption.locator(`[data-test='${hook}']`).evaluate((el) => getComputedStyle(el).color);
    expect(contrast(parse(colour).slice(0, 3), backdrop), `${opened} ${hook} ${colour} on the page`).toBeGreaterThanOrEqual(4.5);
  }
  const card = await page.locator(OPEN_CARD).boundingBox();
  const [name, host, blurb] = await Promise.all(["build-example-name", "build-example-host", "build-example-blurb"]
    .map((hook) => caption.locator(`[data-test='${hook}']`).boundingBox()));
  expect(name.y - (card.y + card.height), "room between the card and the name").toBeGreaterThanOrEqual(24);
  expect(host.y - (name.y + name.height), "the host sits tight under the name").toBeLessThanOrEqual(8);
  expect(blurb.y - (host.y + host.height), "a clear gap before the blurb").toBeGreaterThanOrEqual(10);

  // The open card wears the violet ring (2px, then a glow); a side card does not.
  await expect.poll(() => ring(page, OPEN_CARD)).toMatch(/0px 0px 0px 2px/);
  expect(await ring(page, `${ROW} .carousel-slide:not([data-current]):not([aria-hidden='true']) [data-portfolio-card]`), "a side card has no ring").not.toMatch(/0px 0px 0px 2px/);

  // Through a move, sampled every frame: never two captions at once, and never a sideways step.
  const at = Math.round((await caption.boundingBox()).x);
  await page.evaluate((selector) => {
    window.portfolioSamples = [];
    const tick = () => {
      window.portfolioSamples.push([...document.querySelectorAll(selector)]
        .filter((el) => Number(getComputedStyle(el).opacity) > 0.02 && getComputedStyle(el).visibility !== "hidden")
        .map((el) => Math.round(el.getBoundingClientRect().x)));
      if (window.portfolioSamples.length < 45) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, CAPTIONS);
  await page.locator(ROW).getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.portfolioSamples.length)).toBe(45);
  const samples = await page.evaluate(() => window.portfolioSamples);
  expect(Math.max(...samples.map((frame) => frame.length)), "never two captions at once").toBeLessThanOrEqual(1);
  expect([...new Set(samples.flat())], "the caption never moves sideways").toEqual([at]);

  const moved = await page.locator(OPEN_CARD).getAttribute("aria-label");
  expect(moved).not.toBe(opened);
  await expect.poll(() => shownCaptions(page), "the caption follows the row").toEqual([moved]);
  await expect.poll(() => stageHeadings(page), "the h2 follows the row").toEqual([moved]);
  await expect.poll(() => ring(page, OPEN_CARD), "the ring follows the row").toMatch(/0px 0px 0px 2px/);

  // Keyboard focus is its own outline, outside the ring.
  await page.locator(OPEN_CARD).focus();
  await page.keyboard.press("Shift+Tab");
  await page.keyboard.press("Tab");
  const focus = await page.evaluate(() => { const style = getComputedStyle(document.activeElement); return { style: style.outlineStyle, offset: style.outlineOffset }; });
  expect(focus, "focus is a solid outline 4px outside the ring").toEqual({ style: "solid", offset: "4px" });

  // Build Your Website sits just under the caption, centred (Alex McRitchie, 2026-11-08).
  const shown = await page.locator(`${OPEN_CAPTION} [data-test='build-example-blurb']`).boundingBox();
  const cta = await page.getByRole("link", { name: "Build Your Website", exact: true }).boundingBox();
  expect(cta.y, "the CTA is below the caption").toBeGreaterThanOrEqual(shown.y + shown.height);
  expect(cta.y - (shown.y + shown.height), "no large gap above the CTA").toBeLessThanOrEqual(80);
  expect(Math.abs(cta.x + cta.width / 2 - 700), "the CTA is centred").toBeLessThanOrEqual(2);
  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
}

test("each card is its still alone, the open one ringed, and the one caption reads at 4.5:1 and cross-fades in place, in the dark theme", async ({ browser }) => {
  await measureCards(browser, "dark");
});

test("each card is its still alone, the open one ringed, and the one caption reads at 4.5:1 and cross-fades in place, in the light theme", async ({ browser }) => {
  await measureCards(browser, "light");
});

test("under reduced motion the caption swaps at once, one at a time", async ({ browser }) => {
  const { context, page } = await openPage(browser, { viewport: { width: 1400, height: 900 }, reducedMotion: "reduce" });
  expect(await page.evaluate(() => window.matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(true);
  const opened = await page.locator(OPEN_CARD).getAttribute("aria-label");
  await page.locator(ROW).getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(() => page.locator(OPEN_CARD).getAttribute("aria-label")).not.toBe(opened);
  const moved = await page.locator(OPEN_CARD).getAttribute("aria-label");
  expect(await shownCaptions(page), "the swap is instant").toEqual([moved]);
  expect(await page.locator(OPEN_CAPTION).evaluate((el) => getComputedStyle(el).transitionDuration)).toMatch(/^0s/);
  await context.close();
});

test("on a phone, the open app's caption shows whole under the stack, with no sideways scroll", async ({ browser }) => {
  const { context, page } = await openPage(browser, devices["iPhone 13"]);
  expect(await page.evaluate(() => window.innerWidth)).toBe(390);
  await expect.poll(() => shownCaptions(page)).toHaveLength(1);
  const box = await page.locator(OPEN_CAPTION).boundingBox();
  expect(box.x, "the caption starts on screen").toBeGreaterThanOrEqual(0);
  expect(box.x + box.width, "the caption ends on screen").toBeLessThanOrEqual(390);
  const blurb = await page.locator(`${OPEN_CAPTION} [data-test='build-example-blurb']`).boundingBox();
  const cta = await page.getByRole("link", { name: "Build Your Website", exact: true }).boundingBox();
  expect(cta.y, "the CTA never sits on the caption").toBeGreaterThanOrEqual(blurb.y + blurb.height);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow, "no sideways page scroll").toBeLessThanOrEqual(0);
  await context.close();
});
