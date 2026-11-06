// [e2e] /websites: the apps ride the engine carousel (studio/_carousel, spotlight style). The
// arrows, the dots and the keys are the controller's, so only a browser shows them working.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, VISITOR, watchPageErrors } = require("./helpers");

async function openCarousel(browser, viewport) {
  const context = await browser.newContext({ storageState: VISITOR, viewport });
  const page = await context.newPage();
  const errors = watchPageErrors(page);
  await blockThirdPartyRequests(page);
  await page.goto("/websites");
  const carousel = page.locator("[data-test='websites-carousel']");
  await expect(carousel).toBeVisible();
  return { context, page, errors, carousel, track: carousel.locator(".carousel-track"), dots: carousel.locator(".carousel-dot") };
}

const scrolled = (track) => track.evaluate((element) => element.scrollLeft);
const currentDot = (dots) => dots.evaluateAll((all) => all.findIndex((dot) => dot.getAttribute("aria-current") === "true"));

// The spotlight opens on the middle app (studio/_carousel start: :middle), so both arrows are
// live at load and each moves one slide.
test("on a wide row, the middle app leads, Next moves one, a dot jumps, and Home goes to the first", async ({ browser }) => {
  const { context, page, errors, carousel, track, dots } = await openCarousel(browser, { width: 1280, height: 800 });
  const middle = Math.floor((await dots.count()) / 2);
  await expect(dots.nth(middle)).toHaveAttribute("aria-current", "true");
  await expect(carousel.getByRole("button", { name: "Previous slide", exact: true })).toHaveAttribute("aria-disabled", "false");
  const start = await scrolled(track);
  expect(start, "the row did not open on the middle app").toBeGreaterThan(0);
  await carousel.getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(() => scrolled(track)).toBeGreaterThan(start);
  await expect.poll(() => currentDot(dots)).toBe(middle + 1);
  await dots.last().click();
  await expect(dots.last()).toHaveAttribute("aria-current", "true");
  await track.focus();
  await page.keyboard.press("Home");
  await expect(dots.first()).toHaveAttribute("aria-current", "true");
  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
});

test("on a phone, the arrow key moves one app and the dots follow", async ({ browser }) => {
  const { context, page, errors, track, dots } = await openCarousel(browser, { width: 390, height: 844 });
  const middle = Math.floor((await dots.count()) / 2);
  await expect(dots.nth(middle)).toHaveAttribute("aria-current", "true");
  const start = await scrolled(track);
  await track.focus();
  await page.keyboard.press("ArrowRight");
  await expect.poll(() => scrolled(track)).toBeGreaterThan(start);
  await expect(dots.nth(middle + 1)).toHaveAttribute("aria-current", "true");
  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
});
