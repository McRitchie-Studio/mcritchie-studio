// [e2e] /websites: the apps ride the engine carousel (studio/_carousel): the cascade style where
// the installed engine has it (Alex McRitchie, 2026-11-08), else the spotlight. The arrows and the
// keys are the controller's, so only a browser shows them working. The row has no dots, no pause
// button and no autoplay (Alex McRitchie, 2026-11-08); the prev and next arrows flank the stack.
// Every check holds on both styles.
const { test, expect, devices } = require("@playwright/test");
const { blockThirdPartyRequests, VISITOR, watchPageErrors } = require("./helpers");

async function openCarousel(browser, options) {
  const context = await browser.newContext({ storageState: VISITOR, ...options });
  const page = await context.newPage();
  const errors = watchPageErrors(page);
  await blockThirdPartyRequests(page);
  await page.goto("/websites");
  const carousel = page.locator("[data-test='websites-carousel']");
  await expect(carousel).toBeVisible();
  await expect(carousel).toHaveAttribute("data-carousel-ready", "");
  return { context, page, errors, carousel };
}

// The open app: the real slide the controller marks data-current (a looping spotlight's seam
// copies are aria-hidden).
const openApp = (carousel) => carousel.locator(".carousel-slide[data-current]:not([aria-hidden='true'])").getAttribute("aria-label");
const appNames = (carousel) => carousel.locator(".carousel-slide:not([aria-hidden='true'])").evaluateAll((all) => all.map((slide) => slide.getAttribute("aria-label")));
const box = (locator) => locator.boundingBox();

// The row opens on the first app (Turf Monster, Alex McRitchie's lead, 2026-11-07) once the
// engine's looping start is installed; an engine before it opens a spotlight on the middle app.
async function openingIndex(carousel) {
  const names = await appNames(carousel);
  await expect.poll(() => openApp(carousel)).not.toBeNull();
  const opened = names.indexOf(await openApp(carousel));
  expect([0, Math.floor(names.length / 2)], `the row opened on ${names[opened]}`).toContain(opened);
  return { names, opened };
}

test("on a wide row, the arrows flank the stack, Next moves one app, Home goes to the first, and nothing autoplays", async ({ browser }) => {
  const { context, page, errors, carousel } = await openCarousel(browser, { viewport: { width: 1400, height: 900 } });
  expect(await page.evaluate(() => window.innerWidth)).toBe(1400);
  const { names, opened } = await openingIndex(carousel);

  // No dots and no pause button: out of the layout, the tab order and the accessibility tree.
  await expect(carousel.locator(".carousel-dot:visible")).toHaveCount(0);
  await expect(carousel.getByRole("group", { name: "Choose a slide" })).toHaveCount(0);
  await expect(carousel.locator(".carousel-autoplay")).toHaveCount(0);
  await expect(carousel).not.toHaveAttribute("data-carousel-autoplay", /.*/);

  // The arrows sit either side of the open card, vertically centred on it, 44px.
  const prev = carousel.getByRole("button", { name: "Previous slide", exact: true });
  const next = carousel.getByRole("button", { name: "Next slide", exact: true });
  const card = await box(carousel.locator(".carousel-slide[data-current] [data-portfolio-card]"));
  const [left, right] = [await box(prev), await box(next)];
  expect(left.x + left.width, "Previous is left of the open card").toBeLessThanOrEqual(card.x);
  expect(right.x, "Next is right of the open card").toBeGreaterThanOrEqual(card.x + card.width);
  for (const arrow of [left, right]) {
    expect(Math.abs(arrow.y + arrow.height / 2 - (card.y + card.height / 2)), "centred on the card").toBeLessThanOrEqual(4);
    expect(arrow.width).toBeGreaterThanOrEqual(44);
    expect(arrow.height).toBeGreaterThanOrEqual(44);
  }
  await expect(prev).toHaveAttribute("aria-disabled", "false");

  await next.click();
  await expect.poll(() => openApp(carousel)).toBe(names[(opened + 1) % names.length]);
  await carousel.locator(".carousel-track").focus();
  await page.keyboard.press("Home");
  await expect.poll(() => openApp(carousel)).toBe(names[0]);

  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
});

test("on a phone, the arrows lie at the edges clear of the open card, and the arrow key moves one app", async ({ browser }) => {
  const { context, page, errors, carousel } = await openCarousel(browser, devices["iPhone 13"]);
  expect(await page.evaluate(() => window.innerWidth)).toBe(390);
  const { names, opened } = await openingIndex(carousel);

  const card = await box(carousel.locator(".carousel-slide[data-current] [data-portfolio-card]"));
  for (const name of ["Previous slide", "Next slide"]) {
    const arrow = await box(carousel.getByRole("button", { name, exact: true }));
    const overlaps = arrow.x < card.x + card.width && arrow.x + arrow.width > card.x;
    expect(overlaps, `${name} does not cover the open card`).toBe(false);
    expect(arrow.x).toBeGreaterThanOrEqual(0);
    expect(arrow.x + arrow.width).toBeLessThanOrEqual(390);
  }

  await carousel.locator(".carousel-track").focus();
  await page.keyboard.press("ArrowRight");
  await expect.poll(() => openApp(carousel)).toBe(names[(opened + 1) % names.length]);
  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
});
