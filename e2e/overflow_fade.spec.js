const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// ===========================================================================
// components/_overflow_fade — ASSERTED ON THE PAINTED PIXELS.
//
// The component renders single-line text in an `overflow-hidden` box, so text
// wider than the box is CUT — mid-glyph, with a hard vertical edge. The fade
// mask is what turns that cut into a taper, and the partial decides whether to
// apply it from `fadeInner.scrollWidth > $el.clientWidth`.
//
// THE BUG THESE SPECS EXIST FOR (task: refresh-overflow-fade-on-resize). That
// decision used to be taken once at init and re-taken on a DEBOUNCED WINDOW
// RESIZE and nothing else. A window resize is one CAUSE of the box changing;
// on this app it is the rarest one. The box also moves when a value paints
// into a neighbouring slot, when a font swaps, when a sibling expands, and
// when a stream replaces the row — none of which resize the window, and all of
// which land AFTER the only measurement anyone took. The sibling bug in
// turf-monster's nav (PR 391) was worse than reported for exactly this reason:
// the mask never applied on the live path at ANY width, because the single
// measurement ran before an async balance finished painting and squeezed the
// box.
//
// WHY PIXELS AND NOT `getComputedStyle(...).maskImage`. Computed style reports
// what the cascade RESOLVED, not what the compositor PAINTED, and those are
// different claims — a mask can resolve to a gradient and still fade nothing
// (wrong geometry, wrong box, a stacking context that drops it). What a reader
// experiences is ink at the cut edge, so ink is what these specs measure:
// three screenshots of the SAME strip, decoded to pixels in-page.
//
//   ref       mask forced fully TRANSPARENT -> the strip with zero ink in it.
//             The background reference; every other sample is diffed against
//             it, so no assertion has to guess a background colour or a theme.
//   unmasked  mask forced OFF               -> the hard clip, full ink.
//   live      whatever the app itself decides.
//
// ink[x] = max channel deviation from `ref` down column x. A faded edge decays
// toward nothing; a hard clip does not.
//
// MEASURED on this app at 1280px, on a 66px-wide box squeezed live: the final
// columns read [.., 40, 24, 9] with the fix and [.., 210, 210, 210] with the
// mask forced off. On the BROKEN build the app's own paint was byte-identical
// to mask-forced-off — not a faint mask over the wrong box, no mask at all,
// which is the distinction `liveEqualsUnmasked` below is here to state.
// The thresholds sit in that gap with room on both sides.
const FADE_TAIL_COLS = 2; // the cut edge itself
const CLIP_VISIBLE_INK = 100; // the strip must SEE the hard clip, or it is blind
const FADE_BODY_INK = 60; // the text must still be painted, not masked away

// THE FADE IS ASSERTED AS A RATIO, NOT AN ABSOLUTE INK LEVEL, and that is a
// correction paid for on CI.
//
// The first version capped the tail at an absolute 80, calibrated on macOS
// where a faded edge measured 24 against a hard clip of 210. On CI the same
// correct build measured 64 at the same place. The cause is the one
// `fadeMeasurement` names below: on CI the captured box ran ~3px WIDER than
// the painted content, so the last PAINTED column sits short of the ramp's
// end, where alpha is `gap / (0.2 * box)` instead of nearly zero. Box width
// alone runs the OTHER way — measured on macOS at gap 0: box 86px => tail 14,
// 66px => 24, 36px => 42, so 66px -> 73px would move the tail DOWN. An
// absolute threshold encodes one machine's geometry; the ratio encodes the
// claim, and does not move with ink level, theme or antialiasing.
//
//   faded on macOS, gap 0px    24 / 210 = 0.11
//   faded on CI,    gap ~3px   64 / 210 = 0.30
//   NO MASK AT ALL             live IS the clip = 1.00
//
// 0.6 sits between 0.30 and 1.00 with room on both sides. That room is finite
// and measured: on a 66px box the ratio crosses 0.6 once the trailing gap
// reaches 7px (6px => 0.49, 7px => 0.64).
const FADE_TAIL_RATIO = 0.6;

const MASK_OFF = "-webkit-mask-image:none;mask-image:none;";
const MASK_BLANK =
  "-webkit-mask-image:linear-gradient(to right,transparent,transparent);" +
  "mask-image:linear-gradient(to right,transparent,transparent);";

const FADE = "[data-overflow-fade]";
const PIN = "[data-pw-fade-pin]";

const SHOT = { caret: "hide" };

// FREEZE THE PAINT BEFORE SAMPLING, and freeze it IN PLACE.
//
// Why it is needed: the board's cards carry a pulsing glow, and three samples
// taken ~100ms apart caught it at three different frames. That showed up as a
// UNIFORM ink difference down every column of the strip — including columns
// holding no text at all (measured: 189 across the whole strip, on a fade
// carrying no mask). Noise arriving in exactly the shape of signal.
//
// Why NOT Playwright's `animations: "disabled"`: it REWINDS every animation to
// its first frame, and this app animates each page swap in from transparent
// (the smooth-load convention). Rewinding therefore renders the entire page
// invisible, and all three samples come back as identical blank strips — every
// ink profile zero, every assertion vacuously agreeing with every other.
// Measured that way too, which is how this note got written.
//
// `animation-play-state: paused` holds each animation at the frame it is
// already on, so the three samples differ only by the mask under test.
async function freezePaint(page) {
  await page.addStyleTag({
    content: "*, *::before, *::after { animation-play-state: paused !important; transition: none !important; }",
  });
  await page.waitForTimeout(150);
}

// Mark ONE fade and address it by that mark for the rest of the measurement.
// Index lookups are not stable across a live board re-render, and a measurement
// that silently changes subject mid-way reports a diff of two elements.
async function pinFade(page, idx) {
  await page.evaluate(([sel, i]) => {
    document.querySelectorAll("[data-pw-fade-pin]").forEach((el) => el.removeAttribute("data-pw-fade-pin"));
    document.querySelectorAll(sel)[i].setAttribute("data-pw-fade-pin", "");
  }, [FADE, idx]);
}

// Every fade on the page, with the two numbers the component decides from.
async function inventory(page) {
  return await page.evaluate((sel) =>
    [...document.querySelectorAll(sel)].map((el, i) => {
      const inner = el.querySelector("[x-ref=fadeInner]");
      const line = el.closest(".aa-r");
      return {
        i,
        text: inner.textContent.trim(),
        sw: inner.scrollWidth,
        cw: el.clientWidth,
        hasChip: !!(line && line.querySelector(".hb-chip")),
        isCardTitle: !!el.closest('[data-test="task-card-title"]'),
      };
    }), FADE);
}

// The two numbers the component decides from, plus its box size — read off the
// pinned element. The BOX POSITION is deliberately not used: see shotWithMask.
async function fadeBox(page) {
  return await page.evaluate((sel) => {
    const el = document.querySelector(sel);
    const r = el.getBoundingClientRect();
    const inner = el.querySelector("[x-ref=fadeInner]");
    return {
      size: `${Math.round(r.width)}x${Math.round(r.height)}`,
      sw: inner.scrollWidth, cw: el.clientWidth,
      text: inner.textContent.trim(),
      style: el.getAttribute("style") || "",
    };
  }, PIN);
}

// Screenshot the strip with `css` appended to the element's own style
// attribute, then put the attribute back exactly as Alpine left it. Nothing
// here changes LAYOUT — a mask is paint only — so the box under measurement
// never moves, and the clip stays valid across all three samples.
// THE ELEMENT ITSELF IS THE FRAME, not a page-coordinate clip.
//
// The clip version of this helper measured three blank strips. `scrollIntoView`
// is ASYNCHRONOUS under a smooth scroll behaviour, so the rect was read before
// the scroll landed and the clip pointed at page coordinates the element had
// since left. All three samples then captured the same innocent region, every
// ink profile came back 0, and `liveEqualsUnmasked` was vacuously true — a
// probe that had stopped looking at its subject while still returning verdicts.
//
// `locator.screenshot()` scrolls the element into view, waits for its box to
// settle, and frames the element. A mask changes paint and never layout, so the
// three samples are the same box by construction — which is also asserted, from
// the size read before and after.
async function shotWithMask(page, css) {
  if (css !== null) {
    await page.evaluate(([sel, c]) => {
      const el = document.querySelector(sel);
      el.dataset.pwSavedStyle = el.getAttribute("style") || "";
      el.setAttribute("style", (el.getAttribute("style") || "") + ";" + c);
    }, [PIN, css]);
  }
  const shot = (await page.locator(PIN).screenshot(SHOT)).toString("base64");
  if (css !== null) {
    await page.evaluate((sel) => {
      const el = document.querySelector(sel);
      el.setAttribute("style", el.dataset.pwSavedStyle || "");
      delete el.dataset.pwSavedStyle;
    }, PIN);
  }
  return shot;
}

// Decode two PNGs INSIDE the page (canvas.getImageData) and return the
// per-column max channel deviation between them.
async function inkProfile(page, aB64, bB64) {
  return await page.evaluate(async ([a, b]) => {
    const load = (d) => new Promise((res, rej) => {
      const img = new Image();
      img.onload = () => res(img);
      img.onerror = rej;
      img.src = "data:image/png;base64," + d;
    });
    const [ia, ib] = await Promise.all([load(a), load(b)]);
    const c = document.createElement("canvas");
    c.width = ia.naturalWidth;
    c.height = ia.naturalHeight;
    const ctx = c.getContext("2d", { willReadFrequently: true });
    ctx.drawImage(ia, 0, 0);
    const da = ctx.getImageData(0, 0, c.width, c.height).data;
    ctx.clearRect(0, 0, c.width, c.height);
    ctx.drawImage(ib, 0, 0);
    const db = ctx.getImageData(0, 0, c.width, c.height).data;
    const cols = [];
    for (let x = 0; x < c.width; x++) {
      let m = 0;
      for (let y = 0; y < c.height; y++) {
        const i = (y * c.width + x) * 4;
        m = Math.max(m,
          Math.abs(da[i] - db[i]),
          Math.abs(da[i + 1] - db[i + 1]),
          Math.abs(da[i + 2] - db[i + 2]));
      }
      cols.push(m);
    }
    return cols;
  }, [aB64, bB64]);
}

// The whole measurement for one fade as it stands RIGHT NOW. The box is
// re-read after the samples and compared, so a strip measured while the page
// was still settling fails loudly instead of reporting a diff of two different
// layouts.
async function fadeMeasurement(page, idx) {
  await pinFade(page, idx);
  // WARM-UP, discarded. The first locator.screenshot() of a run scrolls the
  // element into view, and whatever the page does in response to that scroll
  // lands between sample one and sample two. Measured without it: the `live`
  // sample differed from BOTH masked samples by a uniform 189 down every
  // column — including columns past the end of the text, where a mask cannot
  // change anything — while the two masked samples were byte-identical to each
  // other. That is the signature of the first frame being a different view, not
  // of a mask.
  await page.locator(PIN).screenshot(SHOT);
  const before = await fadeBox(page);
  const live = await shotWithMask(page, null);
  const ref = await shotWithMask(page, MASK_BLANK);
  const unmasked = await shotWithMask(page, MASK_OFF);
  const after = await fadeBox(page);
  expect(after.size,
    `the box RESIZED while it was being measured, so the three samples are not ` +
    `the same frame (${JSON.stringify(before)} -> ${JSON.stringify(after)})`)
    .toBe(before.size);

  const liveInk = await inkProfile(page, live, ref);
  const clipInk = await inkProfile(page, unmasked, ref);

  // WHERE THE PAINT ACTUALLY ENDS, learned from the hard-clip sample rather
  // than assumed to be the last column of the capture. On CI the element's
  // captured box ran 3px WIDER than its painted content — an ancestor clip
  // under table-layout:fixed — so the final columns were empty in EVERY
  // sample. Measured there: clip [210,210,210,210,203,0,0,0] against live
  // [108,93,78,64,48,0,0,0]. Reading the last two columns of that is reading
  // two columns of nothing, which made the probe's own self-check report "the
  // strip cannot see the clip" and fail a build that was painting correctly.
  const edge = (() => {
    for (let x = clipInk.length - 1; x >= 0; x -= 1) if (clipInk[x] > 0) return x;
    return clipInk.length - 1;
  })();
  const tail = (cols) =>
    Math.max(...cols.slice(Math.max(0, edge - FADE_TAIL_COLS + 1), edge + 1));
  const body = (cols) => Math.max(...cols.slice(0, Math.floor(cols.length / 2)));

  return {
    text: before.text, sw: before.sw, cw: before.cw, style: before.style,
    cutEdgeCol: edge, capturedCols: clipInk.length,
    liveTailInk: tail(liveInk),
    clipTailInk: tail(clipInk),
    liveBodyInk: body(liveInk),
    // Is the app's paint indistinguishable from having no mask at all?
    liveEqualsUnmasked: live === unmasked,
    liveInkTail8: liveInk.slice(-8),
    clipInkTail8: clipInk.slice(-8),
  };
}

// The text IS cut, and the cut IS tapered.
function expectFaded(m, where) {
  const msg = `${where}: ${JSON.stringify(m)}`;
  // PROBE SELF-CHECK. If the strip cannot see the hard clip it is about to
  // claim was faded, every assertion under it is unfalsifiable.
  expect(m.clipTailInk, `${msg}\n  the strip must SEE hard-clipped ink at the edge`)
    .toBeGreaterThanOrEqual(CLIP_VISIBLE_INK);
  expect(m.sw, `${msg}\n  precondition: this text must actually be overflowing`)
    .toBeGreaterThan(m.cw);
  // The bug, stated as the reader met it: the app painted EXACTLY as though
  // the mask did not exist.
  expect(m.liveEqualsUnmasked, `${msg}\n  the app's paint is byte-identical to having NO mask`)
    .toBe(false);
  // THE FADE, in paint — as a fraction of the ink the hard clip leaves at the
  // very same columns, so the verdict does not move with the runner's fonts.
  expect(m.liveTailInk / m.clipTailInk,
    `${msg}\n  the clipped edge must be FADED, not cut`)
    .toBeLessThanOrEqual(FADE_TAIL_RATIO);
  // ...and a fade, not an erasure: masking the whole text away would also
  // empty the tail.
  expect(m.liveBodyInk, `${msg}\n  the text itself must still be PAINTED`)
    .toBeGreaterThanOrEqual(FADE_BODY_INK);
}

// THE NEGATIVE CONTROL. Text that fits must be painted with no mask at all —
// this is what "mask everything" cannot pass.
function expectUnmasked(m, where) {
  const msg = `${where}: ${JSON.stringify(m)}`;
  expect(m.sw, `${msg}\n  precondition: this text must NOT overflow`)
    .toBeLessThanOrEqual(m.cw);
  expect(m.liveEqualsUnmasked, `${msg}\n  text that fits must be painted UNMASKED`)
    .toBe(true);
  // ...and the strip was pointed at the text, not at an empty box, so the
  // equality above means something.
  expect(m.liveBodyInk, `${msg}\n  the strip must have the TEXT in it`)
    .toBeGreaterThanOrEqual(FADE_BODY_INK);
}

// A NEGATIVE CONTROL IS ONLY A CONTROL IF IT COULD FAIL.
//
// The mask ramp starts at 80 percent of the box, so text that stops short of
// that mark is painted IDENTICALLY whether the mask is applied or not — the
// gradient is fading a region that holds no ink. Measured: a build that masks
// unconditionally is byte-identical to the correct build on a fade with
// sw/cw = 0.35, and a control built on one waves that build straight through.
// (That is not hypothetical; it is what the first draft of this spec did.)
//
// So the control is aimed to leave its text reaching INTO the ramp, and the
// aim is asserted before the control's verdict is trusted.
const MASK_RAMP_START = 0.8;

function expectSensitiveControl(m, where) {
  expect(m.sw / m.cw,
    `${where}: this control's text stops before the mask ramp ` +
    `(${MASK_RAMP_START} of the box), so an unconditional mask would paint it ` +
    `identically and the control below proves nothing: ${JSON.stringify(m)}`)
    .toBeGreaterThan(MASK_RAMP_START);
  expectUnmasked(m, where);
}

// Widen the chip sharing this fade's flex line by `delta` px. This is the same
// layout event as an async value painting into that slot — the flex line
// re-solves and the fade's box shrinks — written as an exact pixel count so a
// spec can aim it. Crucially it touches a SIBLING: the fade's own element is
// never written to, and the window never resizes.
async function widenNeighbour(page, idx, delta) {
  await page.evaluate(([sel, i, d]) => {
    const el = document.querySelectorAll(sel)[i];
    const chip = el.closest(".aa-r").querySelector(".hb-chip");
    chip.style.width = `${chip.getBoundingClientRect().width + d}px`;
  }, [FADE, idx, delta]);
  await page.waitForTimeout(300);
}

async function openActivities(page) {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/agents/activities");
  await expect(page.locator(FADE).first()).toBeVisible();
  await page.waitForTimeout(800);
  await freezePaint(page);
}

test("a neighbour widening re-fades the clipped text, and leaves a fitting label alone",
  async ({ page }) => {
    test.setTimeout(90_000);
    await openActivities(page);

    // Two fades that FIT at load, each sharing its row with a category chip.
    // Fitting at load is the whole point: it is the state the old code cached
    // and never revisited.
    const fits = (await inventory(page)).filter((f) => f.hasChip && f.sw + 80 < f.cw);
    expect(fits.length,
      "this page must render at least two fades that fit at load, or there is " +
      "nothing to make stale").toBeGreaterThanOrEqual(2);

    const target = fits[0];
    const control = fits[1];

    // Nothing is masked yet — the honest starting point for both.
    expectUnmasked(await fadeMeasurement(page, target.i), "target BEFORE the neighbour widened");

    // THE POSITIVE CASE. Squeeze the target's box 60px past its text. No window
    // resize, no touch of the fade element, no navigation.
    await widenNeighbour(page, target.i, target.cw - target.sw + 60);
    expectFaded(await fadeMeasurement(page, target.i), "target AFTER a neighbour widened");

    // THE NEGATIVE CONTROL. The control's box changes too — so its observer
    // fires just as often — but stops 20px SHORT of its text. A build that
    // masks on any box change, or masks unconditionally, reddens here. 20px is
    // chosen so the text reaches past the 80-percent ramp: see
    // expectSensitiveControl for why a roomier control cannot detect that.
    await widenNeighbour(page, control.i, Math.max(10, control.cw - control.sw - 20));
    expectSensitiveControl(await fadeMeasurement(page, control.i),
      "control AFTER the same neighbour widening");

    // AND THE PATH THE OLD CODE DID COVER still works — removing the debounced
    // window listener must not have cost the case it did handle. Data-driven,
    // because a narrower viewport does not narrow every box: this table
    // redistributes its columns, and the target measured here went from 66px
    // back to 281px and legitimately stopped overflowing. So the claim is the
    // PROPERTY, at whatever the new layout turns out to be — every fade is
    // masked exactly when its text does not fit.
    await page.setViewportSize({ width: 700, height: 900 });
    await page.waitForTimeout(500);

    const after = await inventory(page);
    const worst = after.reduce((a, b) => (b.sw - b.cw > a.sw - a.cw ? b : a));
    const roomiest = after.reduce((a, b) => (b.cw - b.sw > a.cw - a.sw ? b : a));
    expect(worst.sw, `a window resize to 700px must leave something overflowing: ` +
      JSON.stringify(worst)).toBeGreaterThan(worst.cw);
    expect(roomiest.cw, `...and something fitting, or the control half of this ` +
      `assertion is vacuous: ${JSON.stringify(roomiest)}`).toBeGreaterThan(roomiest.sw);

    expectFaded(await fadeMeasurement(page, worst.i), "widest overflow after a WINDOW resize to 700px");
    expectUnmasked(await fadeMeasurement(page, roomiest.i), "roomiest fade after a WINDOW resize to 700px");
  });

test("the fade follows the TEXT growing inside a box that never moved", async ({ page }) => {
  test.setTimeout(90_000);
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  // The BOARD, not the activities table, and the difference is the point: a
  // task card's title sits in a `display:block` link inside a grid-sized card,
  // so its box width is fixed by the column and cannot be pushed around by its
  // own content. That is what makes this case prove the INNER observer instead
  // of re-proving the outer one.
  await page.goto("/tasks");
  await expect(page.locator(FADE).first()).toBeVisible();
  await page.waitForTimeout(800);
  await freezePaint(page);

  // CARD TITLES ONLY, for two independent reasons. The title's box is a
  // `display:block` link filling a grid-sized card, so its width genuinely
  // cannot be pushed around by its own content — which is the property this
  // spec leans on. And it is the highest-contrast fade on the page: the note
  // preview beneath it is 11px secondary text and carries about 20 units of
  // ink in total, which is not enough signal to tell a fade from an erasure.
  const fits = (await inventory(page)).filter((f) => f.isCardTitle && f.sw > 40 && f.sw + 40 < f.cw);
  expect(fits.length, "the board must render a card title that fits at load")
    .toBeGreaterThanOrEqual(1);
  // The one closest to its edge, so the font has the least distance to travel.
  const target = fits.reduce((a, b) => (b.sw / b.cw > a.sw / a.cw ? b : a));

  // A precondition, not the negative control — the board's titles are not
  // guaranteed to sit close enough to their edge to be sensitive to an
  // unconditional mask. That control is engineered, and asserted sensitive, in
  // the neighbour-widening spec above.
  expectUnmasked(await fadeMeasurement(page, target.i), "BEFORE the text grew");

  // A FONT SWAP, delivered the way a real one arrives: through the CASCADE, not
  // through the element's inline style. That distinction is load-bearing —
  // Alpine owns the inner span's `style` attribute and rewrites it wholesale on
  // every re-measure, so an inline probe mutation ERASES ITSELF and measures
  // nothing (observed: scrollWidth identical before and after).
  //
  // The size is derived from this fade's own numbers rather than picked, so the
  // spec cannot quietly stop overflowing when the seeded titles change.
  const grew = await page.evaluate(([sel, i]) => {
    const el = document.querySelectorAll(sel)[i];
    const inner = el.querySelector("[x-ref=fadeInner]");
    const cwBefore = el.clientWidth;
    const px = parseFloat(getComputedStyle(inner).fontSize);
    const wanted = Math.ceil(px * ((el.clientWidth + 60) / inner.scrollWidth));
    inner.setAttribute("data-pw-late-font", "");
    const style = document.createElement("style");
    style.textContent = `[data-pw-late-font]{font-size:${wanted}px}`;
    document.head.appendChild(style);
    return { cwBefore, fromPx: px, toPx: wanted };
  }, [FADE, target.i]);
  await page.waitForTimeout(400);

  const m = await fadeMeasurement(page, target.i);
  // The precondition that makes this spec prove the inner observer. A container
  // that moved would mean the outer observer could have caught this too.
  expect(m.cw, `the container must NOT have changed size, or this case is the ` +
    `previous one in disguise: ${JSON.stringify({ ...grew, ...m })}`).toBe(grew.cwBefore);
  expectFaded(m, `after the text grew from ${grew.fromPx}px to ${grew.toPx}px inside an unchanged box`);
});

// ===========================================================================
// THE OBSERVER LEDGER.
//
// Turbo caches the live DOM and re-inits Alpine over the restored tree, so a
// component that binds something without releasing it leaves one behind PER
// NAVIGATION. `ResizeObserver` is wrapped at document_start and every
// construct / observe / disconnect is recorded, which is the only way to see
// an observer that is still running against a detached node: nothing about
// such an observer is visible in the DOM, and nothing logs.
//
// Counted by TARGET, not globally: the ledger only claims anything about
// observers that were pointed at a fade, so an unrelated component's observer
// can neither mask a leak here nor be blamed for one.
const RO_LEDGER = () => {
  const Native = window.ResizeObserver;
  const stats = { constructed: 0, disconnected: 0, records: [] };
  const isFade = (t) => t && t.nodeType === 1 &&
    (t.matches("[data-overflow-fade]") || t.closest("[data-overflow-fade]") !== null);
  window.ResizeObserver = class extends Native {
    constructor(cb) {
      super(cb);
      stats.constructed += 1;
      this.__rec = { targets: [], alive: true };
      stats.records.push(this.__rec);
    }
    observe(target, options) {
      this.__rec.targets.push(target);
      super.observe(target, options);
    }
    disconnect() {
      if (this.__rec.alive) { this.__rec.alive = false; stats.disconnected += 1; }
      super.disconnect();
    }
  };
  window.__fadeObserverLedger = () => {
    const mine = stats.records.filter((r) => r.targets.some(isFade));
    const live = mine.filter((r) => r.alive);
    return {
      constructedAllTime: stats.constructed,
      fadeObserversEverBuilt: mine.length,
      fadeObserversLive: live.length,
      fadeObserversDetached: live.filter((r) => !r.targets.every((t) => document.contains(t))).length,
      fadesInDom: document.querySelectorAll("[data-overflow-fade]").length,
    };
  };
};

test("one live observer per fade survives eight Turbo hops, Back and Forward included",
  async ({ page }) => {
    test.setTimeout(120_000);
    await page.addInitScript(RO_LEDGER);
    await page.setViewportSize({ width: 1280, height: 900 });
    await loginWithMagicLink(page, "alex@test.com");
    await page.goto("/tasks");
    await expect(page.locator(FADE).first()).toBeVisible();
    await page.waitForTimeout(800);

    const read = async () => await page.evaluate(() => window.__fadeObserverLedger());
    const check = (led, where) => {
      const msg = `${where}: ${JSON.stringify(led)}`;
      expect(led.fadeObserversDetached, `${msg}\n  observers still running against detached nodes`)
        .toBe(0);
      expect(led.fadeObserversLive, `${msg}\n  exactly one live observer per fade in the DOM`)
        .toBe(led.fadesInDom);
    };

    const start = await read();
    expect(start.fadesInDom, "the board must render fades to count").toBeGreaterThan(0);
    check(start, "hop 0 (first load)");

    // Real in-page clicks and real history moves. `page.goto()` cannot stand in
    // for either: it is a full document load, which never touches Turbo's
    // snapshot cache AND resets this ledger, so a leak would be invisible.
    const ledgers = [start];
    for (let hop = 0; hop < 4; hop += 1) {
      await page.locator('[data-test="task-card-title"]').first().click();
      await page.waitForURL(/\/tasks\/[^/]+$/);
      await page.waitForTimeout(600);
      ledgers.push(await read());
      check(ledgers[ledgers.length - 1], `hop ${hop * 2 + 1} (task detail)`);

      await page.goBack();
      await page.waitForURL(/\/tasks$/);
      await page.waitForTimeout(600);
      ledgers.push(await read());
      check(ledgers[ledgers.length - 1], `hop ${hop * 2 + 2} (Back to the board)`);

      if (hop === 1) {
        await page.goForward();
        await page.waitForURL(/\/tasks\/[^/]+$/);
        await page.waitForTimeout(600);
        check(await read(), "Forward to the task detail");
        await page.goBack();
        await page.waitForURL(/\/tasks$/);
        await page.waitForTimeout(600);
        check(await read(), "Back again from Forward");
      }
    }

    // ASSERT THE ADVANCE, not just the end state. If a hop had reloaded the
    // document the ledger would have been re-installed from zero and every
    // check above would pass while proving nothing. Observers accumulating
    // all-time is what says the hops happened on ONE document.
    const last = await read();
    expect(last.fadeObserversEverBuilt,
      `the hops must have BUILT observers on one continuous document — ` +
      `${JSON.stringify({ start, last })}`)
      .toBeGreaterThan(start.fadeObserversEverBuilt * 3);
    check(last, "after eight hops");
  });
