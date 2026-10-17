const { test } = require("@playwright/test");
const { expectLanesFitAndClear } = require("./lane_pin_helpers");

// THE LANE COUNT UNDER CLASSIC 17px SCROLLBARS (board-lanes-by-board-width).
//
// A window media query measures the window INCLUDING a classic scrollbar, which the board
// never gets. With the old `max-[1399px]` breakpoint, a 1400px window with a 17px scrollbar
// showed six lanes on a 1319px board that needs 1328px: the lanes overflowed, the sideways
// scroller came on, and every header stopped pinning. Overlay scrollbars (macOS default,
// and Playwright's) hide that, which is why this needs its own file.
//
// HOW THE SCROLLBAR IS FORCED: Playwright launches headless Chromium with
// `--hide-scrollbars`; dropping that default flag brings the platform scrollbar back, and a
// `::-webkit-scrollbar` width pins it to 17px on every OS (Linux CI draws 15px, macOS
// overlays). Each case asserts the measured gutter is 17px, so an overlay scrollbar can
// never pass for a classic one. A launch option is file-wide, so these live apart from
// e2e/deployments_lane_pin.spec.js.
test.use({ launchOptions: { ignoreDefaultArgs: ["--hide-scrollbars"] } });

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    document.addEventListener("DOMContentLoaded", () => {
      const style = document.createElement("style");
      style.textContent = "::-webkit-scrollbar { width: 17px; height: 17px; }";
      document.head.appendChild(style);
    });
  });
});

// 1400 - 17 - the page gutters leaves a 1319px board: three lanes, never six overflowing.
test("with a classic scrollbar at 1400px the board shows three lanes and every header pins", async ({ page }) => {
  await expectLanesFitAndClear(page, 1400, { lanes: 3, scrollbar: 17 });
});

// The last width short of six: a 1327px board.
test("with a classic scrollbar at 1408px the board shows three lanes and every header pins", async ({ page }) => {
  await expectLanesFitAndClear(page, 1408, { lanes: 3, scrollbar: 17 });
});

// The first width that holds six: a 1328px board, 83rem exactly.
test("with a classic scrollbar at 1409px the board shows six lanes and every header pins", async ({ page }) => {
  await expectLanesFitAndClear(page, 1409, { lanes: 6, scrollbar: 17 });
});

test("with a classic scrollbar at 1416px the board shows six lanes and every header pins", async ({ page }) => {
  await expectLanesFitAndClear(page, 1416, { lanes: 6, scrollbar: 17 });
});
