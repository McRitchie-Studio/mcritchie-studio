const { test, expect } = require("@playwright/test");

// The Google booking frame (schedule/_booking_frame), on / and on /schedule.
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

const frame = (page) => page.locator("iframe[data-booking-frame]");

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

test("the frame is cropped to the slot picker at rest and opens fully once it is used", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/schedule");
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);

  const wrap = page.locator("[data-booking-wrap]");
  const heights = () =>
    wrap.evaluate((el) => [Math.round(el.getBoundingClientRect().height), el.querySelector("iframe").offsetHeight]);

  // At rest the wrapper shows a 414px window onto a 732px frame.
  expect(await heights()).toEqual([414, 732]);

  // A click inside the frame moves focus into it; the parent sees only a blur.
  await page.frameLocator("iframe[data-booking-frame]").locator("#stub").click();
  await expect(wrap).toHaveClass(/is-open/);
  await expect.poll(async () => (await heights())[0]).toBe(732);
});
