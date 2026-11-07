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

// The row loops, so both arrows are live at load and each moves one slide. It opens on the
// first app (Turf Monster, Alex McRitchie's lead, 2026-11-07) once the engine's visual wrap
// is installed (a looping spotlight starts at slide 0, the last app on its left); an engine
// before it opens a spotlight on the middle app. Either opening passes; the move from it is
// what is measured.
const openingDot = async (dots) => {
  const middle = Math.floor((await dots.count()) / 2);
  await expect.poll(() => currentDot(dots)).toBeGreaterThanOrEqual(0);
  const opened = await currentDot(dots);
  expect([0, middle], `the row opened on dot ${opened}, neither the first nor the middle app`).toContain(opened);
  return opened;
};

test("on a wide row, the lead app opens, Next moves one, a dot jumps, and Home goes to the first", async ({ browser }) => {
  const { context, page, errors, carousel, track, dots } = await openCarousel(browser, { width: 1280, height: 800 });
  const opened = await openingDot(dots);
  await expect(carousel.getByRole("button", { name: "Previous slide", exact: true })).toHaveAttribute("aria-disabled", "false");
  const start = await scrolled(track);
  await carousel.getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(() => scrolled(track)).toBeGreaterThan(start);
  await expect.poll(() => currentDot(dots)).toBe(opened + 1);
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
  const opened = await openingDot(dots);
  const start = await scrolled(track);
  await track.focus();
  await page.keyboard.press("ArrowRight");
  await expect.poll(() => scrolled(track)).toBeGreaterThan(start);
  await expect(dots.nth(opened + 1)).toHaveAttribute("aria-current", "true");
  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
});
