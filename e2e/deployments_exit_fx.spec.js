const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// [e2e] The EXIT animations on the live /deployments board — what an operator watches
// during a deploy (a card moving column to column) and during the archive sweep
// (overlapping removals from one column).
//
// [e2e] The MOVE exit: a card that leaves its column
// slides off to the RIGHT and fades before the fresh card grows in at its new column
// (LiveBoardFx.flyOutGhost). This is the animation a production deploy plays, once
// per member, as the batch flips assembled → shipped.
//
// WHY A GHOST AT ALL, since this spec asserts one: a move arrives as ONE Turbo payload
// — remove the old card, then prepend a freshly rendered card WITH THE SAME ID — so
// the real node has to go on Turbo's schedule or the remove swallows its own
// replacement. The animation therefore runs on a clone parked over the card's last
// position. That clone is [data-test='card-fly-out'], and it must clean itself up.
//
// EACH TEST SETS ITS OWN prefers-reduced-motion, with page.emulateMedia rather than
// the suite's `use.reducedMotion` — MEASURED on Playwright 1.58.2: the config option
// leaves `matchMedia("(prefers-reduced-motion: reduce)").matches` FALSE in the page,
// and this pair of specs is precisely a claim about that media query. Emulating it
// per page is the spelling the browser actually honours.

// Watch the ghosts a page creates: their x position and opacity at birth and again
// mid-flight, recorded in the page so the assertions read measurements, not timing luck.
async function recordGhosts(page) {
  await page.evaluate(() => {
    window.__ghosts = [];
    const sample = (node) => ({ x: node.getBoundingClientRect().x, opacity: Number(getComputedStyle(node).opacity) });
    new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        mutation.addedNodes.forEach((node) => {
          if (node.nodeType !== 1 || !node.dataset || node.dataset.test !== "card-fly-out") return;
          const record = { start: sample(node), peak: null };
          window.__ghosts.push(record);
          // WATCH THE WHOLE FLIGHT, FRAME BY FRAME — never sample at a fixed wall-clock
          // offset. This used to be `setTimeout(() => record.mid = sample(node), 320)`,
          // and the numbers say why that could only ever work by luck:
          //
          //   _deployments_live_fx.html.erb: SLIDE_OFF_MS = 300
          //   slide.finished.then(() => ghost.remove())   <- the ghost is DELETED the
          //                                                 instant the animation ends
          //
          // So the old sample fired 20ms AFTER the node it measures is scheduled to be
          // removed. It passed only while removal happened to lag the timer. Starve the
          // timer — which is what a loaded CI runner does — and it fires later still,
          // long after removal; getBoundingClientRect() on a detached node returns all
          // zeros, x reads 0, and `x > start.x + 10` fails on a perfectly healthy
          // animation. Measured 2026-08-18: the identical spec failed the same shard on
          // two branches with no code in common.
          //
          // The lesson generalises past this spec: an assertion whose truth depends on
          // WHEN it samples is not testing the behaviour, it is testing the scheduler.
          //
          // Tracking per animation frame answers the question the test actually asks —
          // DID the ghost travel right and fade — instead of a proxy for it. It records
          // the furthest x and the faintest opacity seen while the node is connected, so
          // it cannot miss the flight by sampling at the wrong instant, and it stops
          // when the ghost leaves rather than at an arbitrary time.
          let peakX = record.start.x;
          let minOpacity = record.start.opacity;
          let frames = 0;
          const track = () => {
            // A detached node reports zeros; freeze what we saw while it was alive.
            if (!node.isConnected) { record.peak = { x: peakX, opacity: minOpacity }; return; }
            const now = sample(node);
            if (now.x > peakX) peakX = now.x;
            if (now.opacity < minOpacity) minOpacity = now.opacity;
            // Safety stop (~4s at 60fps) so a ghost that never leaves still resolves
            // rather than polling forever and timing the test out with no diagnosis.
            if (++frames > 240) { record.peak = { x: peakX, opacity: minOpacity }; return; }
            requestAnimationFrame(track);
          };
          requestAnimationFrame(track);
        });
      }
    }).observe(document.body, { childList: true });
  });
}

async function openBoard(page, motion) {
  await page.emulateMedia({ reducedMotion: motion });
  await page.goto("/deployments");
}

async function moveTask(page, slug, stage) {
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.patch(`/api/v1/tasks/${slug}`, {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { stage, event: { source: "cli", actor: "steffon" } },
  });
  expect(res.ok()).toBeTruthy();
}

const shipTask = (page, slug) => moveTask(page, slug, "shipped");

test("a card moving to Shipped slides off to the right, fades, and cleans up its ghost", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await openBoard(page, "no-preference");
  await expect(page.locator("#dropzone-assembled #card-live-ship-slide-demo")).toBeVisible();
  await recordGhosts(page);

  await shipTask(page, "live-ship-slide-demo");

  // The card lands in Shipped (no reload)…
  await expect(page.locator("#dropzone-shipped #card-live-ship-slide-demo")).toBeVisible({ timeout: 10_000 });
  // …and exactly one ghost carried it out of Assembled, watched across its whole flight.
  await expect
    .poll(async () => page.evaluate(() => window.__ghosts.filter((g) => g.peak).length), { timeout: 10_000 })
    .toBe(1);

  const ghost = await page.evaluate(() => window.__ghosts[0]);
  // The FURTHEST right and the FAINTEST seen across the whole flight, not a snapshot at
  // one instant — so this asserts the property (it slid right and faded) rather than a
  // position at a time nobody controls.
  expect(ghost.peak.x).toBeGreaterThan(ghost.start.x + 10); // slid RIGHT, not up or down
  expect(ghost.peak.opacity).toBeLessThan(ghost.start.opacity); // and faded on the way

  // The ghost is a picture, not a component: it leaves nothing behind.
  await expect(page.locator("[data-test='card-fly-out']")).toHaveCount(0, { timeout: 10_000 });
  expect(pageErrors, report()).toHaveLength(0);
});

// The sweep is a metronome: one card per beat, and each card is GONE before the next
// one starts. An exit longer than the beat overlaps its neighbour — two cards fading
// at once over a column re-flowing under both, which is what "not organized" looks
// like. Driven here at the server's own cadence, read off the board.
test("each card is gone before the next one starts leaving", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await openBoard(page, "no-preference");
  // Read the beat off the board rather than restating it. A hardcoded copy went
  // stale the day the cadence changed and failed as though the animation were
  // broken; the board renders this straight from Release::BOARD_FLIP_CADENCE.
  const BEAT_MS = Number(await page.getAttribute("[data-test='kanban-board']", "data-beat-ms"));
  expect(BEAT_MS).toBeGreaterThan(0);
  const shipped = page.locator("#dropzone-shipped");
  await expect(shipped.locator("#card-live-exit-beat-a")).toBeVisible();

  // In the page: when each exit STARTS (its remove stream) and when the card is
  // actually gone from the DOM (its exit animation finished).
  await page.evaluate(() => {
    window.__beats = { started: {}, gone: {} };
    document.addEventListener("turbo:before-stream-render", (event) => {
      const stream = event.target;
      const target = stream.getAttribute("target") || "";
      if (stream.getAttribute("action") !== "remove" || !target.startsWith("card-live-exit-beat")) return;
      window.__beats.started[target] = performance.now();
    });
    const watching = ["card-live-exit-beat-a", "card-live-exit-beat-b", "card-live-exit-beat-c"];
    const tick = () => {
      watching.forEach((id) => {
        if (window.__beats.started[id] && !window.__beats.gone[id] && !document.getElementById(id)) {
          window.__beats.gone[id] = performance.now();
        }
      });
      window.__raf = requestAnimationFrame(tick);
    };
    tick();
  });

  for (const slug of ["live-exit-beat-a", "live-exit-beat-b", "live-exit-beat-c"]) {
    await moveTask(page, slug, "archived");
    await page.waitForTimeout(BEAT_MS);
  }
  await expect(shipped.locator("#card-live-exit-beat-c")).toHaveCount(0, { timeout: 10_000 });

  const beats = await page.evaluate(() => {
    cancelAnimationFrame(window.__raf);
    return window.__beats;
  });
  const ids = ["card-live-exit-beat-a", "card-live-exit-beat-b", "card-live-exit-beat-c"];
  ids.forEach((id) => {
    expect(beats.started[id], `${id} never started leaving`).toBeGreaterThan(0);
    expect(beats.gone[id], `${id} never finished leaving`).toBeGreaterThan(0);
    expect(beats.gone[id] - beats.started[id], `${id} took longer than one beat to leave`)
      .toBeLessThan(BEAT_MS);
  });
  ids.slice(1).forEach((id, i) => {
    expect(beats.gone[ids[i]], `${ids[i]} was still leaving when ${id} started`)
      .toBeLessThanOrEqual(beats.started[id]);
  });
  expect(pageErrors, report()).toHaveLength(0);
});

// The ARCHIVE sweep removes cards one after another from the SAME column, and an
// exiting card is absolutely positioned INSIDE that column. The first card to finish
// used to un-position the column while the second was still animating in it: the
// second card's containing block became the page and it jumped to the document's
// top-left corner, sailing across the header. Overlapping exits are the whole test.
test("overlapping archive exits both stay inside their column", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await openBoard(page, "no-preference");
  const shipped = page.locator("#dropzone-shipped");
  await expect(shipped.locator("#card-live-exit-hold-a")).toBeVisible();
  await expect(shipped.locator("#card-live-exit-hold-b")).toBeVisible();

  // Sample every frame for a card that has escaped its column — the failure mode is
  // a containing-block change, so ASK THE BROWSER what it is positioned against.
  await page.evaluate(() => {
    window.__escaped = [];
    const tick = () => {
      document.querySelectorAll(".kanban-card").forEach((card) => {
        if (getComputedStyle(card).position !== "absolute") return;
        const parent = card.offsetParent;
        if (parent && parent.id === "dropzone-shipped") return;
        window.__escaped.push({ id: card.id, offsetParent: parent ? (parent.id || parent.tagName) : null });
      });
      window.__raf = requestAnimationFrame(tick);
    };
    tick();
  });

  // Back to back, well inside the ~760ms archive exit, so the two overlap.
  await moveTask(page, "live-exit-hold-a", "archived");
  await page.waitForTimeout(200);
  await moveTask(page, "live-exit-hold-b", "archived");

  await expect(shipped.locator("#card-live-exit-hold-a")).toHaveCount(0, { timeout: 10_000 });
  await expect(shipped.locator("#card-live-exit-hold-b")).toHaveCount(0, { timeout: 10_000 });

  const escaped = await page.evaluate(() => {
    cancelAnimationFrame(window.__raf);
    return window.__escaped;
  });
  expect(escaped, `cards positioned outside the Shipped column: ${JSON.stringify(escaped.slice(0, 3))}`).toHaveLength(0);
  expect(pageErrors, report()).toHaveLength(0);
});

test("the same move under reduced motion lands the card with no ghost at all", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await openBoard(page, "reduce");
  await expect(page.locator("#dropzone-assembled #card-live-ship-slide-calm-demo")).toBeVisible();
  await recordGhosts(page);

  await shipTask(page, "live-ship-slide-calm-demo");

  await expect(page.locator("#dropzone-shipped #card-live-ship-slide-calm-demo")).toBeVisible({ timeout: 10_000 });
  expect(await page.evaluate(() => window.__ghosts.length)).toBe(0);
  expect(pageErrors, report()).toHaveLength(0);
});
