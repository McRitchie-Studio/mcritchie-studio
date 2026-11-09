// [e2e] /websites portfolio cards (Alex McRitchie, 2026-11-08): the app's still is the whole
// card, and one caption under the row (the carousel's caption:) carries the open app's name,
// host and blurb, changing as the row moves. Only a browser resolves which caption shows and
// the colours a visitor sees, so both are measured here, on the computed styles, against the
// page behind the caption. Every check holds on the cascade and on the spotlight.
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

const ROW = "[data-test='websites-carousel']";
const OPEN_CAPTION = `${ROW} .carousel-slide[data-current] [data-test='portfolio-caption']`;

// The names on the captions a visitor can see: the open slide's only.
const shownCaptions = (page) => page.locator(`${ROW} .carousel-caption`).evaluateAll((all) =>
  all.filter((caption) => getComputedStyle(caption).opacity !== "0" && getComputedStyle(caption).visibility !== "hidden" && caption.getBoundingClientRect().height > 0)
    .map((caption) => caption.querySelector("[data-test='build-example-name']").textContent.trim()));

// The level-2 headings the accessibility tree holds for the row: the open app's caption only.
const rowHeadings = async (page) => (await page.locator(ROW).ariaSnapshot()).split("\n")
  .map((line) => line.match(/heading "(.*)" \[level=2\]/)).filter(Boolean).map((match) => match[1]);

// The first opaque background colour behind an element, else the page's.
const backdropOf = (locator) => locator.evaluate((element) => {
  for (let node = element; node; node = node.parentElement) {
    const parts = getComputedStyle(node).backgroundColor.match(/[\d.]+/g).map(Number);
    if (parts.length === 3 || parts[3] === 1) return getComputedStyle(node).backgroundColor;
  }
  return getComputedStyle(document.documentElement).backgroundColor;
});

// Every card is the still alone, filling it; the one caption shown reads at 4.5:1 on the page
// behind it and changes with the row. In one hub theme; each theme is its own bare test below.
async function measureCards(browser, scheme) {
  const context = await browser.newContext({ storageState: VISITOR, viewport: { width: 1400, height: 900 }, colorScheme: scheme });
  const page = await context.newPage();
  const errors = watchPageErrors(page);
  await blockThirdPartyRequests(page);
  await page.goto("/websites");
  // The hub's theme is the dark class on <html>, not the browser's scheme.
  await page.evaluate((dark) => document.documentElement.classList.toggle("dark", dark), scheme === "dark");
  expect(await page.evaluate(() => window.innerWidth)).toBe(1400);
  // Real slides only: the spotlight's visual wrap adds aria-hidden copies at the seam.
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
      words: card.querySelector("[data-test='build-example-name'], [data-test='build-example-blurb']"),
    };
  }).map((card) => ({ ...card, words: card.words !== null })));
  expect(measured.filter((card) => card.fills).length, "at least four apps show a still").toBeGreaterThanOrEqual(4);
  for (const card of measured) {
    expect(card.fills, `${card.name}: a still fills the whole card`).not.toBe(false);
    expect(card.words, `${card.name}: nothing is written over the still`).toBe(false);
  }

  await expect.poll(() => shownCaptions(page)).toHaveLength(1);
  const [opened] = await shownCaptions(page);
  // One h2 in the outline, the open app's, though every slide renders a caption.
  await expect.poll(() => rowHeadings(page)).toEqual([opened]);
  expect(await page.getByRole("heading", { level: 1 }).allTextContents()).toEqual(["Portfolio"]);
  const caption = page.locator(OPEN_CAPTION);
  const backdrop = parse(await backdropOf(caption)).slice(0, 3);
  for (const hook of ["build-example-name", "build-example-host", "build-example-blurb"]) {
    const colour = await caption.locator(`[data-test='${hook}']`).evaluate((el) => getComputedStyle(el).color);
    expect(contrast(parse(colour).slice(0, 3), backdrop), `${opened} ${hook} ${colour} on the page`).toBeGreaterThanOrEqual(4.5);
  }

  // The open app's card wears the violet ring (2px, then a glow); a side card does not.
  const ring = (selector) => page.locator(`${ROW} ${selector} .portfolio-card`).first().evaluate((card) => getComputedStyle(card).boxShadow);
  await expect.poll(() => ring(".carousel-slide[data-current]")).toMatch(/0px 0px 0px 2px/);
  expect(await ring(".carousel-slide:not([data-current]):not([aria-hidden='true'])"), "a side card has no ring").not.toMatch(/0px 0px 0px 2px/);

  await page.locator(ROW).getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(async () => (await shownCaptions(page)).join()).not.toBe(opened);
  expect(await shownCaptions(page), "one caption at a time").toHaveLength(1);
  await expect.poll(() => rowHeadings(page), "the h2 follows the row").toEqual(await shownCaptions(page));
  await expect.poll(() => ring(".carousel-slide[data-current]"), "the ring follows the row").toMatch(/0px 0px 0px 2px/);
  // Keyboard focus is its own outline, outside the ring.
  await page.locator(`${ROW} .carousel-slide[data-current] .portfolio-card`).focus();
  await page.keyboard.press("Shift+Tab");
  await page.keyboard.press("Tab");
  const focus = await page.evaluate(() => { const style = getComputedStyle(document.activeElement); return { style: style.outlineStyle, offset: style.outlineOffset }; });
  expect(focus, "focus is a solid outline 4px outside the ring").toEqual({ style: "solid", offset: "4px" });
  // Build yours sits under the row's controls, centred (Alex McRitchie, 2026-11-08).
  const controls = await page.locator(`${ROW} .carousel-controls`).boundingBox();
  const cta = await page.locator("[data-test='websites-build-cta']").boundingBox();
  expect(cta.y, "Build yours is below the arrows and dots").toBeGreaterThanOrEqual(controls.y + controls.height);
  expect(Math.abs(cta.x + cta.width / 2 - 700), "Build yours is centred").toBeLessThanOrEqual(2);
  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
}

test("each card is its still alone, and the one caption reads at 4.5:1 and follows the row, in the dark theme", async ({ browser }) => {
  await measureCards(browser, "dark");
});

test("each card is its still alone, and the one caption reads at 4.5:1 and follows the row, in the light theme", async ({ browser }) => {
  await measureCards(browser, "light");
});

test("on a phone, the open app's caption shows whole under the row, with no sideways scroll", async ({ browser }) => {
  const context = await browser.newContext({ ...devices["iPhone 13"], storageState: VISITOR });
  const page = await context.newPage();
  await blockThirdPartyRequests(page);
  await page.goto("/websites");
  expect(await page.evaluate(() => window.innerWidth)).toBe(390);
  await expect.poll(() => shownCaptions(page)).toHaveLength(1);
  const box = await page.locator(OPEN_CAPTION).boundingBox();
  expect(box.x, "the caption starts on screen").toBeGreaterThanOrEqual(0);
  expect(box.x + box.width, "the caption ends on screen").toBeLessThanOrEqual(390);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow, "no sideways page scroll").toBeLessThanOrEqual(0);
  await context.close();
});
