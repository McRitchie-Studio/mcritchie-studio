const { test, expect } = require("@playwright/test");

// SCROLL TO THE BOTTOM OF THE BOARD, not the bottom of the DOCUMENT.
//
// These checks are about a lane header pinning *while its own lane scrolls beneath it*, and
// a sticky header only sticks inside its own containing block — past the board it is
// SUPPOSED to travel up and out. `scrollTo(0, document.scrollHeight)` meant "past the
// board's top" only for as long as the board happened to be the last thing on the page,
// which is a proxy, not the property. /deployments now renders a desk panel below the board
// (tasks/_desk_panel), so the document bottom is well past the lanes and the old scroll
// asserted a header should pin somewhere it must not.
//
// This addresses the board directly, so it means the same thing it always did — and stays
// true whatever the page grows underneath. It clamps to the document, so a page where the
// board IS last scrolls exactly as far as before.
async function scrollToBoardBottom(page) {
  await page.evaluate(() => {
    const board = document.querySelector("[data-test='kanban-board']");
    const bottom = board.getBoundingClientRect().bottom + window.scrollY;
    const max = document.documentElement.scrollHeight - window.innerHeight;
    window.scrollTo(0, Math.max(0, Math.min(bottom - window.innerHeight, max)));
  });
}

// THE PINNED STACK on /deployments, in a real browser: the site nav, then the swim-lane
// headers sitting on its bottom edge.
//
// WHY THIS CAN ONLY BE A BROWSER CHECK. Every part of it is geometry. The integration
// tier proves the header is `position: sticky` and takes a measured top; it cannot prove
// the header ENDS UP there, and the two failure modes this feature actually has are both
// invisible to it:
//
//   · A scroll-container ancestor. `sm:overflow-x-auto` on the lane row makes every
//     sticky header stick to a scrollport with no vertical scroll of its own, so it
//     rides the page up and out of view. Measured: `top: -552px` while the computed
//     style still read `position: sticky`. Nothing in the markup says anything is wrong.
//   · A stale offset. The nav changes its height as it collapses, so a reading taken
//     on the scroll event alone is behind by a frame and the headers settle into a gap
//     or under the nav.
//
// A WIDE VIEWPORT, like the other Deployments specs: the six-lane board collapses its
// upstream lanes below 1400px, and the lane row only drops its scroller — the thing that
// lets the headers pin at all — when the lanes fit without one.
test.use({ viewport: { width: 1600, height: 800 } });

test("the lane headers pin under the site header while cards scroll beneath", async ({
  page,
}) => {
  await page.goto("/deployments");

  const headers = page.locator("[data-test='stage-header']");
  const count = await headers.count();
  expect(count, "the board must have lanes for this to mean anything").toBeGreaterThan(0);

  // Before scrolling, the headers sit in the flow, below the fold's top chrome.
  const restingTop = await headers.first().evaluate((el) => Math.round(el.getBoundingClientRect().top));
  expect(restingTop, "nothing is pinned while the board's top is on screen").toBeGreaterThan(200);

  await scrollToBoardBottom(page);

  // POLLED, because the nav's shrink lands after the scroll event that triggered it.
  // What is asserted is that the stack CONVERGES.
  await expect
    .poll(
      async () =>
        page.evaluate(() => {
          const nav = document.querySelector(".vt-pinned-header");
          const navBottom = Math.round(nav.getBoundingClientRect().bottom);
          const tops = Array.from(document.querySelectorAll("[data-test='stage-header']"))
            .filter((el) => el.getBoundingClientRect().width > 0)
            .map((el) => Math.round(el.getBoundingClientRect().top));
          return tops.every((t) => Math.abs(t - navBottom) <= 2);
        }),
      { message: "every lane header settles on the site header's bottom edge" }
    )
    .toBe(true);

  // AND THEY ARE ON SCREEN, which is the point. A sticky header inside a scroll-container
  // ancestor keeps `position: sticky` and quietly leaves the viewport instead.
  const seen = await headers.evaluateAll((els) =>
    els
      .filter((el) => el.getBoundingClientRect().width > 0)
      .map((el) => ({
        stage: el.dataset.stage,
        top: Math.round(el.getBoundingClientRect().top),
        position: getComputedStyle(el).position,
        // Aligned with the lane it names — the property a fixed clone would have to
        // re-derive and this shape gets for free.
        left: Math.round(el.getBoundingClientRect().left),
        laneLeft: Math.round(
          el.parentElement.querySelector(".kanban-dropzone").getBoundingClientRect().left
        ),
      }))
  );

  expect(seen.length).toBeGreaterThan(0);
  for (const lane of seen) {
    expect(lane.position, `${lane.stage} must stay sticky`).toBe("sticky");
    expect(lane.top, `${lane.stage} left the screen instead of pinning`).toBeLessThan(300);
    expect(lane.top, `${lane.stage} slid above the viewport`).toBeGreaterThan(0);
    expect(
      Math.abs(lane.left - lane.laneLeft),
      `${lane.stage} drifted off the lane it names`
    ).toBeLessThanOrEqual(1);
  }
});

// THE ANCESTOR RULE, asserted as itself. This is the defect that shipped a `position:
// sticky` header doing nothing at all, and it is one computed style away from returning
// — any future `overflow-x: auto` on the lane row, at any breakpoint, re-arms it.
test("the lane row is not a scroll container while the lanes fit", async ({ page }) => {
  await page.goto("/deployments");

  const lanes = page.locator("[data-test='kanban-lanes']");
  const read = await lanes.evaluate((el) => ({
    overflowX: getComputedStyle(el).overflowX,
    overflowY: getComputedStyle(el).overflowY,
    scrollWidth: el.scrollWidth,
    clientWidth: el.clientWidth,
  }));

  expect(read.scrollWidth, "six lanes fit this viewport without a scroller").toBeLessThanOrEqual(
    read.clientWidth + 1
  );
  expect(read.overflowX, "a scroll container here un-sticks every header").toBe("visible");
  // Stated because it is the half nobody expects: a box with one axis scrollable
  // computes the OTHER axis from `visible` to `auto`, and that is what captures sticky.
  expect(read.overflowY, "and it captures sticky through the y axis, not the x").toBe("visible");
});

// The headers stand down with everything else: back at the top of the page they are in
// the flow again, so the board reads as it always did.
test("the lane headers return to the flow at the top of the page", async ({ page }) => {
  await page.goto("/deployments");
  await scrollToBoardBottom(page);
  await page.waitForTimeout(400);
  await page.evaluate(() => window.scrollTo(0, 0));

  await expect
    .poll(async () =>
      page.evaluate(() =>
        Math.round(document.querySelector("[data-test='stage-header']").getBoundingClientRect().top)
      )
    )
    .toBeGreaterThan(200);
});

// NOTHING FROM A LANE PAINTS OVER ITS PINNED HEADER — asserted by HIT-TESTING, because
// that is the only reading that answers the question actually asked. "Does the header
// have the highest z-index" is a different question and a card won it: the crew stack in
// components/_stage_agent_avatars layers its faces z-10/20/30/40 to order them WITHIN a
// card, but nothing between them and the root created a stacking context, so a z-40
// badge was bidding against the page and beat the z-30 header it should slide under.
// Reported by the operator, visible as a mascot portrait sitting on top of "BUILDING 2".
//
// The fix is `isolate` on each dropzone, which contains those numbers per lane. Raising
// the header instead would only move the collision — the nav is z-50 — so what is pinned here is the PROPERTY (the header is what you see and what
// you would click), not any particular number, and every future z-index inside a card is
// covered by the same assertion.
test("nothing from a lane paints over its pinned header", async ({ page }) => {
  await page.goto("/deployments");

  const overlaps = [];

  // SEVERAL SCROLL POSITIONS: the offender is whatever happens to be passing under the
  // band at that moment, so one position proves nothing about the next.
  for (const y of [700, 900, 1100, 1400]) {
    await page.evaluate((to) => window.scrollTo(0, to), y);
    await page.waitForTimeout(300);

    const found = await page.evaluate((at) => {
      const out = [];
      document.querySelectorAll("[data-test='stage-header']").forEach((header) => {
        const box = header.getBoundingClientRect();
        if (box.width === 0 || box.top < 0) return;

        // A GRID over the whole band, not its centre: the crew stack sits left of centre
        // and the count badge right of the label, so a centre-only probe walks past the
        // two things most likely to be on top.
        for (const fx of [0.08, 0.25, 0.5, 0.75, 0.92]) {
          for (const fy of [0.25, 0.5, 0.75]) {
            const el = document.elementFromPoint(
              Math.round(box.left + box.width * fx),
              Math.round(box.top + box.height * fy)
            );
            if (!el || !el.closest("[data-test='stage-header']")) {
              out.push({
                scroll: at,
                stage: header.dataset.stage,
                at: `${fx}/${fy}`,
                painted: el ? el.className.toString().slice(0, 60) || el.tagName : "nothing",
              });
            }
          }
        }
      });
      return out;
    }, y);

    overlaps.push(...found);
  }

  expect(overlaps, "a card element is painting over a pinned lane header").toEqual([]);
});

// THE MECHANISM behind the spec above, stated once so a future edit that removes it fails
// with the reason attached rather than as a mystery hit-test.
test("each lane contains its cards' stacking so their z-indexes stay internal", async ({
  page,
}) => {
  await page.goto("/deployments");

  const isolations = await page
    .locator(".kanban-dropzone")
    .evaluateAll((els) => els.map((el) => getComputedStyle(el).isolation));

  expect(isolations.length).toBeGreaterThan(0);
  for (const isolation of isolations) {
    expect(isolation, "a lane without its own stacking context leaks card z-indexes").toBe(
      "isolate"
    );
  }
});

// A LANE HEADER NEVER COVERS ITS LANE'S FIRST CARD (board-lane-header-overlap).
//
// From 1400 to 1439px the six lanes, at a 13.5rem floor, measured 1376px against a
// board 10-40px narrower, so the measured scroller came on. Inside it each sticky
// header was offset by its pinned-stack `top` from the SCROLLER's top edge, which
// pushed it down over its own cards: 123px at rest, 36px with the navbar collapsed.
// So: at those widths the six lanes fit and the headers pin, and wherever the
// scroller does come on (All Stages on a narrow window) the headers stop pinning.
async function headerClearance(page) {
  return page.evaluate(() => {
    const lanes = document.querySelector("[data-test='kanban-lanes']");
    const gaps = [...document.querySelectorAll("[data-test='stage-header']")]
      .filter((h) => h.getBoundingClientRect().width > 0)
      .map((h) => {
        // The first card under the header: the first bordered box in the lane, outside the header.
        const card = [...h.parentElement.querySelectorAll("*")].find((el) =>
          !h.contains(el) && el.getBoundingClientRect().height > 80 && getComputedStyle(el).borderTopWidth !== "0px");
        return card ? card.getBoundingClientRect().top - h.getBoundingClientRect().bottom : null;
      })
      .filter((gap) => gap !== null);
    return { gaps, scroller: getComputedStyle(lanes).overflowX };
  });
}

for (const width of [1300, 1400, 1430]) {
  test(`at ${width}px the lanes fit, their headers pin, and none covers its first card`, async ({ page }) => {
    await page.setViewportSize({ width, height: 650 });
    await page.goto("/deployments");
    for (const y of [0, 150]) {
      await page.evaluate((top) => window.scrollTo(0, top), y);
      await page.waitForTimeout(250);
      const { gaps, scroller } = await headerClearance(page);
      expect(scroller, "the lanes fit without the scroller").toBe("visible");
      expect(gaps.length, "the board must have cards for this to mean anything").toBeGreaterThan(0);
      gaps.forEach((gap) => expect(gap, `y=${y}: ${JSON.stringify(gaps)}`).toBeGreaterThanOrEqual(0));
    }
    // And they really pin: scrolled into the board, each header sits on the
    // navbar's bottom edge, or the clearance above would pass for nothing.
    await scrollToBoardBottom(page);
    await expect.poll(() => page.evaluate(() => {
      const nav = document.querySelector("header").getBoundingClientRect().bottom;
      return [...document.querySelectorAll("[data-test='stage-header']")]
        .filter((h) => h.getBoundingClientRect().width > 0)
        .map((h) => Math.round(Math.abs(h.getBoundingClientRect().top - nav)));
    })).toEqual(expect.arrayContaining([0]));
  });
}

test("with the lanes scrolling sideways the headers stop pinning, clear of their cards", async ({ page }) => {
  await page.setViewportSize({ width: 1300, height: 650 });
  await page.goto("/deployments");
  // All Stages forces the six lanes into a board that cannot hold them.
  await page.evaluate(() => {
    const board = document.querySelector("[data-test='kanban-lanes']").closest("[x-data]");
    window.Alpine.$data(board).showAllCols = true;
  });
  await expect(page.locator("[data-test='kanban-lanes']")).toHaveAttribute("data-lane-scroll", "true");
  const header = page.locator("[data-test='stage-header']").first();
  await expect.poll(() => header.evaluate((h) => getComputedStyle(h).position)).toBe("static");
  for (const y of [0, 150]) {
    await page.evaluate((top) => window.scrollTo(0, top), y);
    await page.waitForTimeout(250);
    const { gaps } = await headerClearance(page);
    expect(gaps.length).toBeGreaterThan(0);
    gaps.forEach((gap) => expect(gap, `y=${y}: ${JSON.stringify(gaps)}`).toBeGreaterThanOrEqual(0));
  }
});
