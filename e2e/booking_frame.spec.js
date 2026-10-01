const { test, expect } = require("@playwright/test");

// The Google booking frame, links and popup, on this app's own pages.
//
// studio-engine renders them (`studio_booking_frame`, `studio_booking_link`, the
// popup the footer carries) and its browser lane proves the scripts on lab
// pages. This spec proves the WIRING here: that /, /schedule, /privacy and
// /about call the engine's helpers in a way its scripts answer to. The scripts
// act only on elements marked data-studio-booking, so a link written by hand,
// or a frame from a leftover local partial, would sit on the page looking right
// and do nothing; the selectors below carry the marker for that reason.
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. The frame's URL waits in data-src and
// an inline script assigns src only after the window's `load` event, once the
// frame is near the viewport: a third-party frame that starts loading earlier
// holds `load` open for as long as Google takes to answer, which is the failure
// third_party_blocked.spec.js documents. The component tier can see data-src in
// the markup. Only a browser shows the script moving it to src, and when.
//
// Google is stubbed: the spec is about WHEN the frame is asked for, and must not
// depend on whether a runner can reach calendar.google.com.

const frame = (page) => page.locator("iframe[data-booking-frame][data-studio-booking]");

async function stubGoogle(page) {
  const asked = [];
  await page.route("https://calendar.google.com/**", (route) => {
    asked.push(route.request().url());
    return route.fulfill({ contentType: "text/html", // 300px down: inside the window the cropped frame shows, so it can be clicked.
      body: "<p id='stub' style='margin-top:300px'>booking stub</p>" });
  });
  return asked;
}

test("the home page asks Google for the booking frame only once it is scrolled to", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 600 });
  const asked = await stubGoogle(page);
  await page.goto("/");

  // `load` has fired (goto waits for it) and the frame is far below the fold.
  await expect(frame(page)).toHaveCount(1);
  expect(await frame(page).getAttribute("src")).toBeNull();
  expect(asked).toEqual([]);

  await frame(page).scrollIntoViewIfNeeded();
  await expect(frame(page)).toHaveAttribute("src", /calendar\.google\.com\/calendar\/appointments\/schedules\/.+gv=true$/);
  await expect(page.frameLocator("iframe[data-booking-frame]").locator("#stub")).toHaveText("booking stub");
  expect(asked).toHaveLength(1);
  // One calendar on the page, and it sits in the tinted Get in Touch band.
  await expect(page.locator("iframe[data-booking-frame]")).toHaveCount(1);
  await expect(page.locator("section[data-get-in-touch] iframe[data-booking-frame]")).toHaveCount(1);
});

test("/schedule shows the frame without scrolling, as wide as its column", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/schedule");

  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);
  // The page column is max-w-4xl (896px) less its side padding.
  const box = await frame(page).boundingBox();
  expect(box.width).toBeGreaterThanOrEqual(820);
  expect(box.width).toBeLessThanOrEqual(896);
});

test("Schedule a call opens the booking popup in place, and Escape closes it", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const asked = await stubGoogle(page);
  await page.goto("/privacy");

  const dialog = page.locator("dialog[data-booking-dialog][data-studio-booking]");
  await expect(dialog).toBeHidden();
  expect(asked).toEqual([]);

  await page.locator("footer[data-site-footer] a[data-booking-popup][data-studio-booking]").click();

  // The visitor stays on the page; the dialog opens and only now asks Google.
  await expect(dialog).toBeVisible();
  await expect(page).toHaveURL(/\/privacy$/);
  await expect(page.frameLocator("iframe[data-booking-popup-frame]").locator("#stub")).toHaveText("booking stub");
  expect(asked).toHaveLength(1);
  expect(await dialog.evaluate((el) => el.matches(":modal"))).toBe(true);

  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
});

test("the About page's own Schedule a call button opens the same popup", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const asked = await stubGoogle(page);
  await page.goto("/about");

  const dialog = page.locator("dialog[data-booking-dialog][data-studio-booking]");
  await expect(dialog).toBeHidden();

  // The page's button, not the footer's link.
  await page.locator("a.btn[data-booking-popup]", { hasText: "Schedule a call" }).click();

  await expect(dialog).toBeVisible();
  await expect(page).toHaveURL(/\/about$/);
  await expect(page.frameLocator("iframe[data-booking-popup-frame]").locator("#stub")).toHaveText("booking stub");
  expect(asked).toHaveLength(1);

  await dialog.locator("[data-booking-close]").click();
  await expect(dialog).toBeHidden();
});

test("on the home page Schedule a call goes to the inline calendar instead of opening a second one", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const asked = await stubGoogle(page);
  await page.goto("/");

  const wrap = page.locator("[data-booking-wrap][data-studio-booking]");
  const dialog = page.locator("dialog[data-booking-dialog][data-studio-booking]");
  const link = page.locator("footer[data-site-footer] a[data-booking-popup][data-studio-booking]");

  // Down the page the way a visitor goes: past the calendar, which loads as it
  // comes into view, to the footer at the bottom.
  await frame(page).scrollIntoViewIfNeeded();
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);
  await expect(wrap).not.toHaveClass(/is-open/);
  await link.scrollIntoViewIfNeeded();
  await expect(wrap).not.toBeInViewport();
  expect(asked).toHaveLength(1);
  await link.click();

  // The visitor stays on /, the popup stays shut, and the inline frame is
  // scrolled back to and opened out of its crop. Google is not asked again:
  // there is still one calendar, and it is the one already loaded.
  await expect(page).toHaveURL(/\/$/);
  await expect(wrap).toBeInViewport();
  await expect(wrap).toHaveClass(/is-open/);
  await expect(dialog).toBeHidden();
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);
  await expect(page.frameLocator("iframe[data-booking-frame]").locator("#stub")).toHaveText("booking stub");
  expect(asked).toHaveLength(1);
});

test("the frame is cropped to the slot picker at rest and opens fully once it is used", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/schedule");
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);

  const wrap = page.locator("[data-booking-wrap][data-studio-booking]");
  // clientHeight is the WINDOW onto the frame: the wrapper's height inside its
  // border. The numbers come from this app's declared crop (config.booking_crop:
  // top 211, bottom 613, frame 869): the engine shows top-6 to bottom+6, a 414px
  // window, onto a frame as tall as Google's page on the fullest day. Engine
  // 0.83.0 fixed the frame at 732px, shorter than that page.
  const heights = () =>
    wrap.evaluate((el) => [el.clientHeight, el.querySelector("iframe").offsetHeight,
                           Math.round(el.getBoundingClientRect().height)]);

  // At rest the wrapper shows a 414px window onto an 869px frame (416px with its borders).
  expect(await heights()).toEqual([414, 869, 416]);

  // A click inside the frame moves focus into it; the parent sees only a blur.
  await page.frameLocator("iframe[data-booking-frame]").locator("#stub").click();
  await expect(wrap).toHaveClass(/is-open/);
  await expect.poll(async () => (await heights())[0]).toBe(869);
});
