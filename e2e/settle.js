// Waits on what the page does, never on the clock. A fixed sleep (`waitForTimeout`)
// guesses how long the page needs, and the guess is short on a loaded runner
// (bin/lib/e2e_race_patterns.rb bans it; Alex McRitchie's deterministic-CI ruling,
// task hub-e2e-real-condition-waits). These are the conditions the old sleeps stood in for.

// `count` animation frames have run in the page. A frame is where the browser applies
// what a script, a scroll or a resize asked for: style, layout, scroll events,
// ResizeObserver callbacks, then requestAnimationFrame callbacks. Two frames cover an
// app that reacts in a frame callback and the layout that reaction causes.
async function frames(page, count = 2) {
  await page.evaluate((n) => new Promise((resolve) => {
    const step = (left) => (left <= 0 ? resolve() : requestAnimationFrame(() => step(left - 1)));
    step(n);
  }), count);
}

// Every running animation and transition with an end has finished: on the whole page, or
// on every element `selector` matches and what is inside them (`subtree: false` for the
// elements alone). Scope it on a live page: a board that restarts a short animation on
// every tick never settles as a whole.
// An endless loop (a glow, a pulse, a typing dot) has no end and is not waited on; a
// paused one is not waited on either. Read again after each round, since one ending can
// start the next.
async function animationsSettled(page, selector = null, { subtree = true } = {}) {
  await page.evaluate(async ({ sel, deep }) => {
    const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
    const ends = (a) => Number.isFinite(a.effect?.getComputedTiming?.().endTime);
    const running = () => {
      const all = sel
        ? [...document.querySelectorAll(sel)].flatMap((el) => el.getAnimations({ subtree: deep }))
        : document.getAnimations();
      return all.filter((a) => a.playState === "running" && ends(a));
    };
    // A selector that matches nothing would settle at once and prove nothing: refuse it.
    if (sel && document.querySelectorAll(sel).length === 0) {
      throw new Error(`animationsSettled: "${sel}" matches no element, so there is nothing to wait on`);
    }
    await frame(); // a transition a style change just asked for exists from the next frame
    for (let now = running(); now.length > 0; now = running()) {
      await Promise.all(now.map((a) => a.finished.catch(() => {})));
      await frame();
    }
  }, { sel: selector, deep: subtree });
}

// Turbo's own "the page is on screen" event, counted on the window (which a Turbo visit
// keeps). Arm before the visit, then wait for the count to pass what it was.
async function armTurboLoads(page) {
  return page.evaluate(() => {
    if (!window.__e2eTurboLoads) {
      window.__e2eTurboLoads = { count: 0 };
      document.addEventListener("turbo:load", () => { window.__e2eTurboLoads.count += 1; });
    }
    return window.__e2eTurboLoads.count;
  });
}

async function turboLoaded(page, after) {
  await page.waitForFunction((was) => (window.__e2eTurboLoads?.count || 0) > was, after);
}

module.exports = { frames, animationsSettled, armTurboLoads, turboLoaded };
