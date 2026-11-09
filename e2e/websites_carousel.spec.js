// [e2e] /websites: the apps ride the engine carousel (studio/_carousel): the cascade style where
// the installed engine has it (Alex McRitchie, 2026-11-08), else the spotlight. The arrows, the
// dots and the keys are the controller's, so only a browser shows them working. Every check
// holds on both styles.
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
  return { context, page, errors, carousel, track: carousel.locator(".carousel-track"), dots: carousel.locator(".carousel-dot") };
}

const scrolled = (track) => track.evaluate((element) => element.scrollLeft);
const isCascade = (carousel) => carousel.evaluate((element) => element.classList.contains("carousel-cascade"));
// Where the row stands: a spotlight scrolls its track; a cascade does not scroll (its slides
// share one cell), so it is the app at the front (data-cascade-step 0).
const front = (carousel) => carousel.locator(".carousel-slide[data-cascade-step='0']").getAttribute("aria-label");
async function expectMoved(carousel, track, start) {
  if (start.cascade) {
    await expect.poll(() => front(carousel)).not.toBe(start.at);
  } else {
    await expect.poll(() => scrolled(track)).toBeGreaterThan(start.at);
  }
}
const standing = async (carousel, track) => (await isCascade(carousel))
  ? { cascade: true, at: await front(carousel) }
  : { cascade: false, at: await scrolled(track) };
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
  const { context, page, errors, carousel, track, dots } = await openCarousel(browser, { viewport: { width: 1400, height: 900 } });
  expect(await page.evaluate(() => window.innerWidth)).toBe(1400);
  const opened = await openingDot(dots);
  await expect(carousel.getByRole("button", { name: "Previous slide", exact: true })).toHaveAttribute("aria-disabled", "false");
  const start = await standing(carousel, track);
  await carousel.getByRole("button", { name: "Next slide", exact: true }).click();
  await expectMoved(carousel, track, start);
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
  const { context, page, errors, carousel, track, dots } = await openCarousel(browser, devices["iPhone 13"]);
  expect(await page.evaluate(() => window.innerWidth)).toBe(390);
  const opened = await openingDot(dots);
  const start = await standing(carousel, track);
  await track.focus();
  await page.keyboard.press("ArrowRight");
  await expectMoved(carousel, track, start);
  await expect(dots.nth(opened + 1)).toHaveAttribute("aria-current", "true");
  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
});
