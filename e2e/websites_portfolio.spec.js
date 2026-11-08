// [e2e] /websites portfolio cards (Alex McRitchie, 2026-11-06): the app's still fills the
// whole card and its name, host and blurb sit on a shade over the lower part. Only a browser
// resolves the custom properties into the colours a visitor sees, so the contrast is measured
// here, on the computed styles, with the shade laid over pure white (the brightest still
// that could ever sit under it).
const { test, expect } = require("@playwright/test");
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

// Every card's text, on its shade over white, in one hub theme. The card's colours are
// fixed, so both themes must measure the same; each theme is its own bare test below.
async function measureCards(browser, scheme) {
  const context = await browser.newContext({ storageState: VISITOR, viewport: { width: 1280, height: 900 }, colorScheme: scheme });
  const page = await context.newPage();
  const errors = watchPageErrors(page);
  await blockThirdPartyRequests(page);
  await page.goto("/websites");
  // Real slides only: the engine's visual wrap adds aria-hidden copies at the seam.
  const cards = page.locator("[data-test='websites-carousel'] .carousel-slide:not([aria-hidden='true']) [data-portfolio-card]");
  expect(await cards.count(), "Cyvasse, Turf Monster and at least two more").toBeGreaterThanOrEqual(4);

  const measured = await cards.evaluateAll((all) => all.map((card) => {
    const body = card.querySelector("[data-test='portfolio-card-body']");
    const image = card.querySelector("[data-test='build-example-image']");
    const box = card.getBoundingClientRect();
    const pic = image && image.getBoundingClientRect();
    const text = ["build-example-name", "build-example-host", "build-example-blurb"].map((hook) => {
      const el = card.querySelector(`[data-test='${hook}']`);
      return { hook, colour: getComputedStyle(el).color };
    });
    return {
      name: card.querySelector("[data-test='build-example-name']").textContent.trim(),
      shade: getComputedStyle(body).backgroundColor,
      // A live showcase app without a still yet (the e2e seed's trivia-night) shows its emoji.
      fills: pic ? Math.abs(pic.width - box.width) < 1 && Math.abs(pic.height - box.height) < 1 : null,
      bodyAtBottom: Math.abs(body.getBoundingClientRect().bottom - box.bottom) < 1,
      text,
    };
  }));

  expect(measured.filter((card) => card.fills).length, "at least four apps show a still").toBeGreaterThanOrEqual(4);
  for (const card of measured) {
    expect(card.fills, `${card.name}: a still fills the whole card`).not.toBe(false);
    expect(card.bodyAtBottom, `${card.name}: the text sits on the lower part`).toBe(true);
    const [r, g, b, alpha] = parse(card.shade);
    expect(alpha, `${card.name}: the shade is see-through, a shade and not a panel`).toBeLessThan(1);
    const backdrop = [r, g, b].map((c) => alpha * c + (1 - alpha) * 255);
    for (const { hook, colour } of card.text) {
      const ratio = contrast(parse(colour).slice(0, 3), backdrop);
      expect(ratio, `${card.name} ${hook} ${colour} on ${card.shade} over white`).toBeGreaterThanOrEqual(4.5);
    }
  }
  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
}

test("every card's text reads at 4.5:1 on its shade over white, in the dark theme", async ({ browser }) => {
  await measureCards(browser, "dark");
});

test("every card's text reads at 4.5:1 on its shade over white, in the light theme", async ({ browser }) => {
  await measureCards(browser, "light");
});

test("on a phone, a card fills the row's slide and its blurb stays within two lines", async ({ browser }) => {
  const context = await browser.newContext({ storageState: VISITOR, viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await blockThirdPartyRequests(page);
  await page.goto("/websites");
  const blurb = page.locator("[data-test='websites-carousel'] [data-test='build-example-blurb']").first();
  const box = await blurb.boundingBox();
  const lineHeight = await blurb.evaluate((el) => parseFloat(getComputedStyle(el).lineHeight));
  expect(box.height).toBeLessThanOrEqual(lineHeight * 2 + 1);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow, "no sideways page scroll").toBeLessThanOrEqual(0);
  await context.close();
});
