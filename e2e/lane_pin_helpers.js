const { expect } = require("@playwright/test");

// Shared by e2e/deployments_lane_pin.spec.js and its classic-scrollbar sibling, which
// must be a separate file: forcing classic scrollbars is a LAUNCH option, and Playwright
// takes launch options only at a file's top level.

// SCROLL TO THE BOTTOM OF THE BOARD, not the bottom of the DOCUMENT.
//
// These checks are about a lane header pinning *while its own lane scrolls beneath it*, and
// a sticky header only sticks inside its own containing block — past the board it is
// SUPPOSED to travel up and out. /deployments renders a desk panel below the board
// (tasks/_desk_panel), so the document bottom is well past the lanes. This addresses the
// board directly, and clamps to the document, so a page where the board IS last scrolls
// exactly as far as the document allows.
async function scrollToBoardBottom(page) {
  await page.evaluate(() => {
    const board = document.querySelector("[data-test='kanban-board']");
    const bottom = board.getBoundingClientRect().bottom + window.scrollY;
    const max = document.documentElement.scrollHeight - window.innerHeight;
    window.scrollTo(0, Math.max(0, Math.min(bottom - window.innerHeight, max)));
  });
}

// The board is wired (its Alpine component has walked its directives and measured once).
async function gotoBoard(page) {
  await page.goto("/deployments");
  await page.waitForSelector("[data-test='kanban-board'][data-alpine-ready]");
}

// Each visible lane header's gap to its lane's first card (negative = it covers the card),
// and whether the lane row is a sideways scroller.
async function headerClearance(page) {
  return page.evaluate(() => {
    const lanes = document.querySelector("[data-test='kanban-lanes']");
    const headers = [...document.querySelectorAll("[data-test='stage-header']")]
      .filter((h) => h.getBoundingClientRect().width > 0);
    const gaps = headers
      .map((h) => {
        // The first card under the header: the first bordered box in the lane, outside the header.
        const card = [...h.parentElement.querySelectorAll("*")].find((el) =>
          !h.contains(el) && el.getBoundingClientRect().height > 80 && getComputedStyle(el).borderTopWidth !== "0px");
        return card ? card.getBoundingClientRect().top - h.getBoundingClientRect().bottom : null;
      })
      .filter((gap) => gap !== null);
    return { headers: headers.length, gaps, scroller: getComputedStyle(lanes).overflowX };
  });
}

// Where the visible lane headers sit against the PINNED NAVBAR (.vt-pinned-header, the
// engine's one site header): how many there are, and the worst distance between a
// header's top and the navbar's bottom. No visible header reads as Infinity, so an empty
// board can never pass for a pinned one.
async function pinReading(page) {
  return page.evaluate(() => {
    const nav = document.querySelector(".vt-pinned-header").getBoundingClientRect().bottom;
    const tops = [...document.querySelectorAll("[data-test='stage-header']")]
      .filter((h) => h.getBoundingClientRect().width > 0)
      .map((h) => Math.abs(h.getBoundingClientRect().top - nav));
    return { count: tops.length, worst: tops.length ? Math.max(...tops) : Infinity };
  });
}

// At one window width, with the given scrollbar: the board shows `lanes` lanes (6, or 3
// once it is too narrow for six), they fit without the sideways scroller, no header
// covers its first card, and once scrolled into the board EVERY header sits within 2px
// of the navbar's bottom.
async function expectLanesFitAndClear(page, width, { lanes, scrollbar = 0 }) {
  await page.setViewportSize({ width, height: 650 });
  await gotoBoard(page);

  // The scrollbar this case claims is really there, or a classic-scrollbar case would
  // pass on an overlay one.
  const gutter = await page.evaluate(() => window.innerWidth - document.documentElement.clientWidth);
  expect(gutter, "the window's scrollbar width").toBe(scrollbar);

  const row = await page.locator("[data-test='kanban-lanes']").evaluate((el) => ({
    visible: [...el.children].filter((c) => c.tagName === "DIV" && c.getBoundingClientRect().width > 0).length,
    scrollWidth: el.scrollWidth,
    clientWidth: el.clientWidth,
    laneScroll: el.getAttribute("data-lane-scroll"),
  }));
  expect(row.visible, `the board's own width decides the lane count at ${width}px`).toBe(lanes);
  expect(row.scrollWidth, "the lanes fit the board").toBeLessThanOrEqual(row.clientWidth + 1);
  expect(row.laneScroll, "the sideways scroller stays off").not.toBe("true");
  // The toggle, and the board switcher's Tasks button (the Build lane, one click away),
  // show exactly when lanes are collapsed: both read the lane row's container query.
  await expect(page.locator("[data-test='all-stages-toggle']")).toBeVisible({ visible: lanes < 6 });
  await expect(page.locator("nav[aria-label='Board views'] a[href='/tasks']")).toBeVisible({ visible: lanes < 6 });

  for (const y of [0, 150]) {
    await page.evaluate((top) => window.scrollTo(0, top), y);
    await page.waitForTimeout(250);
    const { headers, gaps, scroller } = await headerClearance(page);
    expect(scroller, "the lanes fit without the scroller").toBe("visible");
    expect(headers, "every visible lane has its header").toBe(lanes);
    expect(gaps.length, "the board must have cards for this to mean anything").toBeGreaterThan(0);
    gaps.forEach((gap) => expect(gap, `y=${y}: ${JSON.stringify(gaps)}`).toBeGreaterThanOrEqual(0));
  }

  // And they really pin: scrolled into the board, EVERY header sits on the navbar's
  // bottom edge, or the clearance above would pass for nothing. Polled, because the
  // navbar's scroll-linked collapse lands after the scroll that triggered it.
  await scrollToBoardBottom(page);
  await expect
    .poll(async () => (await pinReading(page)).worst, {
      message: "every lane header settles within 2px of the pinned navbar's bottom",
    })
    .toBeLessThanOrEqual(2);
  expect((await pinReading(page)).count, "and every visible lane's header is among them").toBe(lanes);
}

module.exports = { scrollToBoardBottom, gotoBoard, headerClearance, pinReading, expectLanesFitAndClear };
