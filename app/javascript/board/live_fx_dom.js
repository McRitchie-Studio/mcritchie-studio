// The /deployments live board effects, wired to the page. Importing this module
// installs window.LiveBoardFx once (a module runs once per page load, and the
// listeners it adds survive Turbo navigations). tasks/_deployments_live_fx imports
// it, and the kanban board's dropzone observer calls LiveBoardFx.onAdd for each
// patched-in card.
//
// The decisions and shapes live in board/live_fx (pure, node-tested). This file reads
// the DOM, asks those functions, and plays the answer. The .lbfx-* CSS it toggles
// stays in tasks/_deployments_live_fx.
import {
  CONFETTI_COUNT, GUST_COUNT, WAKE_COUNT, MIST_COUNT,
  SLIDE_OFF_RIGHT, SLIDE_OFF_MS, GAP_CLOSE_MS, GROW_IN, GROW_IN_MS, HANDOFF_OPACITY,
  ARRIVAL_CEILING_MS, STREAM_PAIR_MS, MOVE_EASING, METER_GLOW_MS, METER_FADE_MS,
  exitAnimation, classifyStream, arrivalKind, changedMeters, releaseSlotEffect, meterKey,
  isDirectiveAttribute, confettiPiece, gustRibbon, wakeRing, mistPuff
} from "board/live_fx";
import { hexToRgb, paintableColor } from "board/colors";
import "board/release_fx_dom";

// Runtime hooks the effects read. data-test doubles as the e2e handle on these
// nodes; the selectors are named once here so the wiring has one place to change.
const METER_SELECTOR = "[data-test='release-phase-meter']";
const LANE_SELECTOR = "[data-test='release-lane']";
const GLOW_HOST_SELECTOR = "[data-test='release-phase-glow-host']";
const FILL_SELECTOR = "[data-test='release-phase-fill']";

function install() {
  // Per-card coordination between the `remove` stream (intercepted) and the
  // `prepend` that follows it on a MOVE.
  const collapsing = new Map();     // cardId -> Promise (settles when its exit hands off)
  const pendingAction = new Map();  // cardId -> 'prepend' | 'append' | 'replace' (the just-seen stream)

  function followingStreamCardIds(stream) {
    const ids = [];
    let next = stream.nextElementSibling;
    while (next && next.tagName && next.tagName.toLowerCase() === "turbo-stream") {
      const template = next.querySelector("template");
      if (template) {
        template.content.querySelectorAll(".kanban-card").forEach((card) => ids.push(card.id));
      }
      next = next.nextElementSibling;
    }
    return ids;
  }

  function stageGlowHex(card) {
    return getComputedStyle(card).getPropertyValue("--task-card-glow-color").trim();
  }

  // Tint + flash the glow from the card's data-glow (mascot type colour).
  function glow(card) {
    const steadyStageGlow = !!card.dataset.stageGlow;
    const rgb = hexToRgb(card.dataset.glow || stageGlowHex(card));
    if (rgb) card.style.setProperty("--lbfx-glow", rgb);
    if (steadyStageGlow) card.classList.add("lbfx-glow-stage");
    card.classList.add("lbfx-glow");
    setTimeout(() => {
      card.classList.remove("lbfx-glow", "lbfx-glow-stage");
      card.style.removeProperty("--lbfx-glow");
    }, 850);
  }

  function meterEntries(root) {
    if (!root) return [];
    return Array.from(root.querySelectorAll(METER_SELECTOR)).map((meter) => {
      const lane = meter.closest(LANE_SELECTOR);
      return { key: meterKey(lane && lane.dataset.repo, meter.dataset.phase), signature: meter.dataset.signature || "", meter };
    });
  }

  // Everything the fx needs to remember about #current-release BEFORE Turbo replaces
  // it, taken in one call so the meter and card readings come from one render.
  function releaseSnapshot(root) {
    const meters = new Map();
    meterEntries(root).forEach((entry) => meters.set(entry.key, entry.signature));
    return { meters, card: root ? (root.dataset.cardSignature || "") : "" };
  }

  let paintCtx = null;
  function canvasCtx() {
    return paintCtx || (paintCtx = document.createElement("canvas").getContext("2d", { willReadFrequently: true }));
  }

  // A 2s ring around one meter's BAR: the engine's .studio-team-glow on the meter's
  // glow host (the wrapper sized to the bar), tinted with the meter's OWN tone read
  // from its fill's computed background colour, so the ring never disagrees with the
  // bar it traces. A transparent or absent fill leaves the knob unset and the
  // primitive's default colour stands. The last 400ms ride the class's own opacity
  // transition, so the ring fades out instead of snapping off.
  //
  // 2s is the CEILING: every release stream is a wholesale replace, so the next CI
  // upsert destroys this node mid-ring. The timers close over THIS render's node, so
  // an older node's cleanup never touches a newer glow.
  function meterGlow(meter) {
    const host = meter.querySelector(GLOW_HOST_SELECTOR) || meter;
    const fill = meter.querySelector(FILL_SELECTOR);
    const color = paintableColor(fill ? getComputedStyle(fill).backgroundColor : "", canvasCtx());
    if (color) host.style.setProperty("--studio-team-glow-color", color);
    host.classList.add("studio-team-glow", "release-meter-glow");
    setTimeout(() => host.style.setProperty("--studio-team-glow-opacity", "0"), METER_GLOW_MS - METER_FADE_MS);
    setTimeout(() => {
      host.classList.remove("studio-team-glow", "release-meter-glow");
      host.style.removeProperty("--studio-team-glow-color");
      host.style.removeProperty("--studio-team-glow-opacity");
      if (!host.getAttribute("style")) host.removeAttribute("style");
    }, METER_GLOW_MS);
  }

  function reviewedGlow(card) {
    card.classList.add("lbfx-reviewed-swell");
    setTimeout(() => card.classList.remove("lbfx-reviewed-swell"), 1000);
  }

  function liftCard(card) {
    document.body.classList.add("lbfx-confetti-active");
    card.classList.add("lbfx-card-front");
    setTimeout(() => card.classList.remove("lbfx-card-front"), 950);
    setTimeout(() => document.body.classList.remove("lbfx-confetti-active"), 1450);
  }

  // Append `count` particles built by `build` over the card's rect and animate each
  // one off the page.
  function spawn(card, count, build) {
    const r = card.getBoundingClientRect();
    if (!r.width) return;
    for (let i = 0; i < count; i++) {
      const p = build(r, i);
      const el = document.createElement("div");
      el.style.cssText = p.cssText;
      document.body.appendChild(el);
      el.animate(p.keyframes, p.options).onfinish = () => el.remove();
    }
  }

  // The full arrival flourish: glow + side confetti, and (unless the caller drives its
  // own scale, e.g. the move grow-in) a pop.
  function burst(card, pop) {
    const r = card.getBoundingClientRect();
    if (!r.width) return;
    if (pop !== false) card.classList.add("lbfx-pop");
    liftCard(card);
    glow(card);
    if (pop !== false) setTimeout(() => card.classList.remove("lbfx-pop"), 520);
    spawn(card, CONFETTI_COUNT, confettiPiece);
  }

  function reviewedBurst(card, pop) {
    const r = card.getBoundingClientRect();
    if (!r.width) return;
    if (pop !== false) card.classList.add("lbfx-reviewed-arrive");
    liftCard(card);
    reviewedGlow(card);
    if (pop !== false) setTimeout(() => card.classList.remove("lbfx-reviewed-arrive"), 740);
    spawn(card, WAKE_COUNT, wakeRing);
    spawn(card, GUST_COUNT, gustRibbon);
  }

  function arrivalBurst(card, pop) {
    if (card.dataset.stage === "reviewed") {
      reviewedBurst(card, pop);
    } else {
      burst(card, pop);
    }
  }

  function animateExit(card, exitAction, done) {
    if (exitAction === "archive") spawn(card, MIST_COUNT, mistPuff);
    const exit = exitAnimation(exitAction);
    card.animate(exit.keyframes, exit.options).onfinish = done;
  }

  function reducedMotion() {
    return !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }

  // FLIP the cards left behind so the column closes the gap smoothly: measure
  // before, transform back to the old position, then transition to the new one.
  // Without it the dropzone's space-y margins snap shut the frame the leaving card
  // drops out of flow.
  function flipSiblings(siblings, beforeTop) {
    siblings.forEach((c, i) => {
      const delta = beforeTop[i] - c.getBoundingClientRect().top;
      if (!delta) return;
      c.style.transition = "none";
      c.style.transform = "translateY(" + delta + "px)";
      requestAnimationFrame(() => {
        c.style.transition = "transform " + GAP_CLOSE_MS + "ms linear";
        c.style.transform = "";
        const clear = () => { c.style.transition = ""; c.style.transform = ""; c.removeEventListener("transitionend", clear); };
        c.addEventListener("transitionend", clear);
      });
    });
  }

  // Alpine initialises anything added to the document, so a clone parked on <body>
  // would re-run the card's directives outside the board's scope and duplicate every
  // id and data-test under it while it lived. Scrub both off before it lands.
  function scrubGhost(root) {
    const strip = (el) => {
      el.removeAttribute("id");
      el.removeAttribute("data-test");
      Array.from(el.attributes).forEach((attr) => {
        if (isDirectiveAttribute(attr.name)) el.removeAttribute(attr.name);
      });
    };
    strip(root);
    root.querySelectorAll("*").forEach(strip);
    return root;
  }

  // The MOVE exit. A move arrives as ONE payload (remove the old card, then prepend a
  // freshly rendered card WITH THE SAME ID), so the real node must go the moment Turbo
  // says so; holding it would let the remove swallow its own replacement. The
  // animation therefore runs on a GHOST: a clone parked over the card's last position
  // that slides off to the right while the column closes behind it. The returned
  // promise is the HAND-OFF: it settles when the ghost has faded past noticing, which
  // is what holdThenGrowIn waits on, so the card is never in two places at once.
  function flyOutGhost(card, remove) {
    if (!card || reducedMotion()) { remove(); return Promise.resolve(); }

    const rect = card.getBoundingClientRect();
    const zone = card.parentElement;
    const siblings = zone ? Array.from(zone.querySelectorAll(":scope > .kanban-card")).filter((c) => c !== card) : [];
    const beforeTop = siblings.map((c) => c.getBoundingClientRect().top);

    const ghost = scrubGhost(card.cloneNode(true));
    ghost.dataset.test = "card-fly-out";
    ghost.style.cssText = "position:fixed;margin:0;pointer-events:none;z-index:45;left:" + rect.left +
      "px;top:" + rect.top + "px;width:" + rect.width + "px;height:" + rect.height + "px;";
    document.body.appendChild(ghost);

    remove();                    // the real node leaves now; the ghost stands in for it
    flipSiblings(siblings, beforeTop);

    const slide = ghost.animate(SLIDE_OFF_RIGHT, { duration: SLIDE_OFF_MS, easing: MOVE_EASING, fill: "forwards" });
    slide.finished.catch(() => {}).then(() => ghost.remove());
    return new Promise((resolve) => {
      const watch = () => {
        if (!document.body.contains(ghost) ||
            Number(getComputedStyle(ghost).opacity) <= HANDOFF_OPACITY) { resolve(); return; }
        requestAnimationFrame(watch);
      };
      requestAnimationFrame(watch);
    });
  }

  // An exiting card is taken out of flow and positioned INSIDE its column, so the
  // column must stay a positioned ancestor for as long as ANY card is still leaving
  // it. Hence a reference count, not a save/restore pair: with a save/restore the
  // first card to finish restores `position` while later cards are mid-animation, and
  // they jump to the document's top-left corner. Batch archives overlap exits.
  const zoneExitHolds = new WeakMap();

  function holdZonePositioned(zone) {
    let hold = zoneExitHolds.get(zone);
    if (!hold) {
      hold = { count: 0, restore: zone.style.position };
      if (getComputedStyle(zone).position === "static") zone.style.position = "relative";
      zoneExitHolds.set(zone, hold);
    }
    hold.count += 1;
  }

  function releaseZonePositioned(zone) {
    const hold = zoneExitHolds.get(zone);
    if (!hold) return;
    hold.count -= 1;
    if (hold.count > 0) return;      // someone else is still leaving this column
    zone.style.position = hold.restore;
    zoneExitHolds.delete(zone);
  }

  // Remove a card while its column reclaims the gap smoothly (FLIP the siblings) so
  // the dropzone's space-y margins cannot pause or snap. Resolves so a move's
  // incoming card can wait.
  function collapseOut(card, done, exitAction) {
    let signalDone;
    const promise = new Promise((res) => { signalDone = res; });
    const finish = () => { if (done) done(); signalDone(); };
    if (!card) { finish(); return promise; }

    const zone = card.parentElement;
    const siblings = zone ? Array.from(zone.querySelectorAll(":scope > .kanban-card")).filter((c) => c !== card) : [];
    const beforeTop = siblings.map((c) => c.getBoundingClientRect().top);

    const rect = card.getBoundingClientRect();
    const zr = zone.getBoundingClientRect();
    const zs = getComputedStyle(zone);
    holdZonePositioned(zone);
    Object.assign(card.style, {
      position: "absolute",
      width: rect.width + "px",
      height: rect.height + "px",
      top: (rect.top - zr.top - (parseFloat(zs.borderTopWidth) || 0) + zone.scrollTop) + "px",
      left: (rect.left - zr.left - (parseFloat(zs.borderLeftWidth) || 0) + zone.scrollLeft) + "px",
      margin: "0", zIndex: exitAction === "archive" ? "35" : "5", pointerEvents: "none", transformOrigin: "center top"
    });
    if (exitAction) card.dataset.exitAction = exitAction;

    flipSiblings(siblings, beforeTop);

    animateExit(card, exitAction, () => { delete card.dataset.exitAction; releaseZonePositioned(zone); finish(); });
    return promise;
  }

  // A move's incoming card: hold it invisible and out of flow (Alpine x-show owns
  // `display`, so use visibility + position) until the outgoing card has gone, then
  // grow it in with the burst.
  function holdThenGrowIn(card, ready) {
    card.style.visibility = "hidden";
    card.style.position = "absolute";
    card.style.pointerEvents = "none";
    Promise.race([ready, new Promise((res) => setTimeout(res, ARRIVAL_CEILING_MS))]).then(() => {
      if (!document.body.contains(card)) return;
      card.style.transition = ""; card.style.transform = "";
      card.style.transformOrigin = "center";
      card.style.opacity = "0";
      card.style.visibility = ""; card.style.position = ""; card.style.pointerEvents = "";
      const grow = card.animate(GROW_IN, { duration: GROW_IN_MS, easing: "ease-out", fill: "both" });
      grow.onfinish = () => { card.style.opacity = ""; card.style.transformOrigin = ""; grow.cancel(); };
      arrivalBurst(card, false);
    });
  }

  // Called by the board's observeLive for each freshly patched-in card.
  function onAdd(node) {
    const moving = node.id ? collapsing.get(node.id) : undefined;
    const kind = arrivalKind({
      id: node.id,
      // A local drag moves a card's node into a new column; that is not a live event.
      // The drag's own broadcast echo arrives after the PATCH, once the flag has
      // cleared, and animates normally.
      dragging: !!window.__lbfxDragging,
      moving: !!moving,
      action: node.id ? pendingAction.get(node.id) : undefined
    });
    if (!kind) return;
    pendingAction.delete(node.id);
    if (kind === "move") {
      collapsing.delete(node.id);
      holdThenGrowIn(node, moving);
    } else if (kind === "replace") {
      requestAnimationFrame(() => glow(node));
    } else {
      requestAnimationFrame(() => arrivalBurst(node, true));
    }
  }

  // Classify every incoming deployments stream; intercept removes to play the exit
  // first (a move's old card and a delete/archive share this path).
  document.addEventListener("turbo:before-stream-render", (event) => {
    const stream = event.target;
    const action = stream.getAttribute("action");
    const target = stream.getAttribute("target") || "";
    const plan = classifyStream({ action, target, followingCardIds: [] });
    if (!plan) return;

    // Release-module swap (#current-release / #last-release): let Turbo replace the
    // slot, then decide what (if anything) plays on the FRESH element. Both readings
    // are taken HERE, before renderNow() destroys the old node. #last-release
    // delegates to the ReleaseFx router, which also reads the server's declared
    // `data-fx` off this stream element.
    if (plan.kind === "release") {
      const node = document.getElementById(target);
      const before = plan.routed ? window.ReleaseFx.snapshot(node) : releaseSnapshot(node);
      const declared = stream.dataset.fx || null;
      const renderNow = event.detail.render;
      event.detail.render = (el) => {
        renderNow(el);
        const fresh = document.getElementById(target);
        if (!fresh) return;
        requestAnimationFrame(() => {
          if (plan.routed) {
            window.ReleaseFx.route(fresh, before, declared);
            return;
          }
          const entries = meterEntries(fresh);
          const moved = changedMeters(before && before.meters, entries);
          const effect = releaseSlotEffect({ moved, before, freshSignature: fresh.dataset.cardSignature });
          if (effect === "meters") moved.forEach((entry) => meterGlow(entry.meter));
          else if (effect === "card") glow(fresh);
        });
      };
      return;
    }

    if (plan.kind === "exit") {
      const removeNow = event.detail.render;
      event.detail.render = (el) => {
        // Whether this remove is half of a MOVE is read when Turbo renders it, from
        // the streams that follow it in the same payload.
        const exit = classifyStream({ action, target, followingCardIds: followingStreamCardIds(stream) });
        if (exit.kind === "move-exit") {
          // A move arrives as one payload: remove old card, then prepend the freshly
          // rendered replacement with the same id. Delaying the remove would let it
          // delete that replacement, so the remove runs at once and a ghost clone
          // carries the slide-off in the real node's place.
          collapsing.set(target, flyOutGhost(document.getElementById(target), () => removeNow(el)));
          setTimeout(() => collapsing.delete(target), STREAM_PAIR_MS);
          return;
        }
        const p = collapseOut(document.getElementById(target), () => removeNow(el), stream.dataset.exitAction);
        collapsing.set(target, p);
        setTimeout(() => collapsing.delete(target), STREAM_PAIR_MS); // not a move if no prepend follows
      };
    } else {
      pendingAction.set(target, plan.action);
      setTimeout(() => pendingAction.delete(target), STREAM_PAIR_MS);
    }
  });

  return { onAdd };
}

window.LiveBoardFx = window.LiveBoardFx || install();
