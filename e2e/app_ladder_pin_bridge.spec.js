const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// ONE known error is excluded, BY EXACT TEXT and for a measured reason.
//
// `Sortable is not defined` is a load race between the vendored SortableJS script
// and kanbanBoard.initSortables(), and it predates this change: measured on an
// untouched `origin/accepted` checkout at 4 of 6 loads, against 2 of 4 on this
// branch. It is a real (if minor) defect in the board's script ordering and it
// deserves its own task; it is not this spec's business, and letting it in would
// make the lane flaky on something these two tests do not touch.
//
// Matched on the exact string rather than a substring or a regex over "Sortable",
// so a DIFFERENT Sortable failure — one this change could actually cause — still
// fails. Anything else at all still fails.
const KNOWN_UNRELATED = ["ReferenceError: Sortable is not defined"];
const ours = (errs) => errs.filter((e) => !KNOWN_UNRELATED.includes(e));

// THE PINNED STRIP, ON THE PATH A PERSON ACTUALLY ARRIVES BY.
//
// THE EVIDENCE GAP THIS CLOSES, and it is the reason this file exists rather than
// another view test. The strip's pinned state lives in an Alpine store, because a
// Turbo broadcast replaces the ladder row wholesale and a component-local flag is
// rebuilt as false on every one — the per-broadcast flash the adoption exists to
// remove. Every guard for that reads SOURCE or renders MARKUP, and the markup is
// byte-identical whether Alpine ever ran. Review proved the hole by re-adding
// `this.$store.appLadder.pinned = false` to the row's init(), reintroducing the
// exact flash, with all 22 runs / 131 assertions still green.
//
// AND THE DEFECT THAT SLIPPED THROUGH IT. The store was armed on `alpine:init`
// alone. That fires once, inside Alpine.start(); a Turbo Drive visit does not
// re-fire it (layouts/application.html.erb:109-113 documents the same rule for its
// own hook). So arriving here by clicking an in-app link left the store undefined,
// `x-show="$store.appLadder.pinned"` threw, and the strip never pinned at all.
// Measured at scrollY=959: direct load gave {pinned:true}, strip at y=53, 0 page
// errors; the Turbo visit gave store UNDEFINED, strip display:none, 13 page errors.
//
// Both failures are invisible without a browser AND a Turbo navigation, which is
// exactly what this spec is: arrive twice, by both paths, and assert the same
// outcome.
test.use({ viewport: { width: 1600, height: 900 } });

// Scroll until the in-flow ladder row has left the top of the page, which is the
// only condition under which the pinned copy is supposed to show.
async function scrollPastTheLadder(page) {
  await page.evaluate(() => {
    const scroller = document.querySelector("[data-test='app-ladder-scroller']");
    const row = scroller.parentElement;
    window.scrollTo(0, row.getBoundingClientRect().bottom + window.scrollY + 80);
  });
  await page.waitForTimeout(400);
}

async function readPinState(page) {
  return page.evaluate(() => {
    const strip = document.querySelector("[data-test='app-ladder-pinned']");
    const header = document.querySelector("[data-test='stage-header']");
    return {
      storeDefined: !!(window.Alpine && Alpine.store && Alpine.store("appLadder")),
      pinned: window.Alpine && Alpine.store && Alpine.store("appLadder")
        ? Alpine.store("appLadder").pinned
        : null,
      stripDisplay: strip ? getComputedStyle(strip).display : null,
      headerTop: header ? Math.round(parseFloat(getComputedStyle(header).top)) : null,
      navBottom: Math.round(document.querySelector("header").getBoundingClientRect().bottom),
    };
  });
}

test("the ladder strip pins on a direct load AND on a Turbo Drive visit", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  // PATH 1 — a direct full load. alpine:init fires here, so this path passed even
  // with the store armed on that event alone.
  await page.goto("/deployments");
  await expect(page.locator("[data-test='app-ladder-row']")).toBeVisible();
  await scrollPastTheLadder(page);
  const direct = await readPinState(page);

  expect(direct.storeDefined, "a direct load must register the store").toBe(true);
  expect(direct.pinned, "and must pin once the row has scrolled away").toBe(true);
  expect(direct.stripDisplay, "so the pinned copy is showing").not.toBe("none");

  // PATH 2 — the ordinary one: arrive by clicking an in-app link, which Turbo
  // Drive handles WITHOUT re-firing alpine:init.
  await page.goto("/");
  // A marker set BEFORE navigating. A full document load destroys the JS context
  // and takes it with it; a Turbo Drive visit swaps the body and leaves it standing.
  // Without this the spec would silently re-run path 1 — same page, same
  // alpine:init — and assert nothing new while looking thorough.
  await page.evaluate(() => {
    window.__survivesTurbo = true;
    const a = document.createElement("a");
    a.href = "/deployments";
    a.id = "e2e-turbo-nav";
    a.textContent = "deployments";
    document.body.appendChild(a);
  });
  await page.click("#e2e-turbo-nav");
  await expect(page.locator("[data-test='app-ladder-row']")).toBeVisible();

  const reallyTurbo = await page.evaluate(() => ({
    noReload: !!window.__survivesTurbo,
    path: location.pathname,
  }));
  expect(reallyTurbo.path, "the click must have navigated to the board").toBe("/deployments");
  expect(
    reallyTurbo.noReload,
    "this must be a Turbo Drive visit, not a full load — a full load re-fires " +
      "alpine:init and the defect this spec exists for cannot appear"
  ).toBe(true);

  await scrollPastTheLadder(page);
  const viaTurbo = await readPinState(page);

  expect(viaTurbo.storeDefined, "a Turbo visit must ALSO register the store — " +
    "alpine:init does not fire again, so turbo:load is the only signal").toBe(true);
  expect(viaTurbo.pinned, "and the strip must pin exactly as it does on a full load").toBe(true);
  expect(viaTurbo.stripDisplay, "the pinned copy must be showing on this path too").not.toBe("none");
  // NOT `toBe(direct.headerTop)`. The nav's collapse is scroll-linked and the two
  // arrival paths reach this scroll position differently, so the exact pin varies by
  // a few px (measured 142 vs 137) while BOTH are correct. The property is that the
  // header sits below the pinned strip on each path — which is what the defect broke:
  // with the store undefined the strip never showed and the header sat on the bare
  // nav at 53px.
  for (const [label, state] of [["direct load", direct], ["Turbo visit", viaTurbo]]) {
    expect(state.headerTop, `${label}: the lane header must sit under the pinned strip, ` +
      "not on the bare nav").toBeGreaterThan(state.navBottom);
  }

  // The store throwing takes measure() down before gauge() and before the
  // ResizeObserver is built, so it surfaces as a burst of page errors rather than
  // one. Any of them fails this.
  expect(ours(pageErrors), report()).toHaveLength(0);
});

// CRITERION 2 ITSELF: the strip must survive the ladder broadcast unflashed.
//
// The row is replaced wholesale by DeploymentsBroadcaster.app_ladder. Re-rendering
// it must NOT walk the strip back through an unpinned state, because that is the
// 99px slam on the board's lane headers this whole change exists to remove. The
// store is what carries the state across the replace; this asserts the OUTCOME, so
// it fails for any reason the state fails to survive — not just the one we fixed.
test("a ladder row replacement leaves the strip pinned, with no unpinned frame", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await page.goto("/deployments");
  await expect(page.locator("[data-test='app-ladder-row']")).toBeVisible();
  await scrollPastTheLadder(page);
  expect((await readPinState(page)).pinned, "precondition: pinned before the replace").toBe(true);

  const result = await page.evaluate(async () => {
    const row = document.getElementById("app-ladder-row");
    const html = row.outerHTML;

    // Sample every frame across the replace, so an unpinned FRAME is caught rather
    // than only an unpinned end state.
    const seen = [];
    let stop = false;
    const sample = () => {
      const s = document.querySelector("[data-test='app-ladder-pinned']");
      seen.push(s ? getComputedStyle(s).display : "absent");
      if (!stop) requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);

    // Replace the row the way the broadcast does, then let Alpine re-initialise it.
    row.outerHTML = html;
    await new Promise((r) => setTimeout(r, 600));
    stop = true;

    const strip = document.querySelector("[data-test='app-ladder-pinned']");
    return {
      unpinnedFrames: seen.filter((d) => d === "none" || d === "absent").length,
      totalFrames: seen.length,
      endDisplay: strip ? getComputedStyle(strip).display : null,
      storePinned: Alpine.store("appLadder") ? Alpine.store("appLadder").pinned : null,
    };
  });

  expect(result.totalFrames, "the sampler must actually have run").toBeGreaterThan(3);
  expect(result.storePinned, "the store must carry the state across the replace").toBe(true);
  expect(result.endDisplay, "and the strip must still be showing afterwards").not.toBe("none");
  expect(
    result.unpinnedFrames,
    `the replaced strip must never paint an unpinned frame; ${result.unpinnedFrames}/` +
      `${result.totalFrames} frames had it hidden or absent — that is the per-broadcast flash`
  ).toBe(0);

  expect(ours(pageErrors), report()).toHaveLength(0);
});
