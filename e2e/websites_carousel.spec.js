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

test("on a wide row, Next moves the apps, a dot jumps, and Home goes back to the first", async ({ browser }) => {
  const { context, page, errors, carousel, track, dots } = await openCarousel(browser, { width: 1280, height: 800 });
  const previous = carousel.getByRole("button", { name: "Previous slides" });
  await expect(previous).toHaveAttribute("aria-disabled", "true");
  await carousel.getByRole("button", { name: "Next slides" }).click();
  await expect.poll(() => scrolled(track)).toBeGreaterThan(0);
  await expect(previous).toHaveAttribute("aria-disabled", "false");
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
  await expect(dots.first()).toHaveAttribute("aria-current", "true");
  await track.focus();
  await page.keyboard.press("ArrowRight");
  await expect.poll(() => scrolled(track)).toBeGreaterThan(0);
  await expect(dots.nth(1)).toHaveAttribute("aria-current", "true");
  expect(errors.pageErrors, errors.report()).toEqual([]);
  await context.close();
});
