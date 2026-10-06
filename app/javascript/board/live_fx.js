// The /deployments live board effects: the decisions and the shapes, with no DOM.
//
// board/live_fx_dom wires these to the page (Turbo stream events, the dropzone
// observer, element.animate). Everything here is a pure function or a constant, so
// node:test can hold it (test/javascript/live_fx_test.js) and a later Stimulus
// controller can import it unchanged.
//
// What plays, by Turbo Stream action (DeploymentsBroadcaster):
//   create (prepend a new card)        -> pop + type-coloured glow flash + confetti
//   reviewed arrival                   -> smooth-sailing gust burst from behind
//   move (remove old + prepend new)    -> a ghost of the old card slides off to the
//                                         right while its column closes the gap, then
//                                         the new card grows in at its new column
//   archive (remove)                   -> the card dissolves into mist
//   delete (remove)                    -> a distinct fadeout
//   replace (intent / in-place)        -> a subtle glow pulse
//   Next Release, a meter moved        -> a 2s ring on THAT meter alone

export const CONFETTI_COLORS = ["#00C4FF", "#34d399", "#f472b6", "#fbbf24", "#a78bfa", "#22d3ee", "#fb7185"];
export const REVIEWED_GUST_COLORS = ["#67e8f9", "#5eead4", "#fef3c7", "#ffffff", "#22d3ee"];
export const MIST_COLORS = ["rgba(226,232,240,.64)", "rgba(191,219,254,.5)", "rgba(203,213,225,.56)", "rgba(255,255,255,.52)"];

export const CONFETTI_COUNT = 34;
export const GUST_COUNT = 32;
export const WAKE_COUNT = 2;
// 18, not 32: the puffs of a whole sweep overlap, and a heavier cloud costs frames
// exactly when the beat needs to read as even.
export const MIST_COUNT = 18;

// A card LEAVING its column for another one (the move exit): slide off to the RIGHT
// and fade, in the reading direction the pipeline runs. Shared by both move paths
// (the ghost and the in-place exit) so the exit looks the same either way. Opacity
// falls with the travel, near-linearly, so the card is visible for almost the whole
// slide: a front-loaded fade leaves an invisible node still sliding while the
// arrival waits on it, which the eye reads as a delay.
export const SLIDE_OFF_RIGHT = [
  { opacity: 1, transform: "translateX(0) scale(1)" },
  { opacity: 0.55, transform: "translateX(58px) scale(.98)", offset: 0.5 },
  { opacity: 0, transform: "translateX(150px) scale(.95)" }
];

// THE BEAT. A batch flip (an archive sweep, a production deploy) moves ONE card every
// beat, the cadence the server schedules (Release::BOARD_FLIP_CADENCE, published on
// the board as data-beat-ms). Every exit is timed to FINISH INSIDE ITS OWN BEAT, which
// is the difference between a metronome and a mush: two cards fading at once while the
// column re-flows under both reads as "not organized". exceedsBeat holds the rule.
export const EXIT_MS = 400;         // card gone at half the beat, then the column rests
export const GAP_CLOSE_MS = 300;    // the column finishes reclaiming the space even sooner
// The arrival at the far end of a MOVE. It reaches full opacity in its first third,
// growing from nearly full size, so the card is readable soon after the other leaves.
export const GROW_IN_MS = 300;
// The move's departure. Shorter than the archive dissolve: a move is half of a
// hand-off, and the other half still has to play inside the same beat.
export const SLIDE_OFF_MS = 300;
export const DELETE_EXIT_MS = 430;
// The arrival is released when the ghost is THIS faint, watched frame by frame rather
// than scheduled: keyframe offsets live in progress space and a timer in wall-clock
// space, and the easing between them is not the identity, so a fraction-of-duration
// timer misses. Reading the opacity is immune to any change of curve or duration.
export const HANDOFF_OPACITY = 0.12;
// The longest a move's arrival waits on its departure before it grows in anyway.
export const ARRIVAL_CEILING_MS = 1000;
// How long a remove or a stream action is remembered while its partner may follow.
export const STREAM_PAIR_MS = 1200;
export const GROW_IN = [
  { opacity: 0, transform: "scale(.82)" },
  { opacity: 1, transform: "scale(.97)", offset: 0.35 },
  { opacity: 1, transform: "scale(1.03)", offset: 0.7 },
  { opacity: 1, transform: "scale(1)" }
];
export const MOVE_EASING = "cubic-bezier(.4,0,.2,1)";

export const ARCHIVE_EXIT = [
  { opacity: 1, filter: "blur(0px)", transform: "scale(1)" },
  { opacity: 0.62, filter: "blur(2px)", transform: "scale(.98)", offset: 0.34 },
  { opacity: 0, filter: "blur(9px)", transform: "scale(.86)" }
];
export const DELETE_EXIT = [
  { opacity: 1, transform: "translateX(0) rotate(0deg) scale(1)", filter: "blur(0)" },
  { opacity: .55, transform: "translateX(8px) rotate(1deg) scale(.96)", filter: "blur(0)", offset: .42 },
  { opacity: 0, transform: "translateX(28px) rotate(-2deg) scale(.72)", filter: "blur(1px)" }
];

// The keyframes and timing a removed card leaves with, by its exit action.
export function exitAnimation(exitAction) {
  if (exitAction === "archive") {
    return { keyframes: ARCHIVE_EXIT, options: { duration: EXIT_MS, easing: "ease-in", fill: "forwards" } };
  }
  if (exitAction === "delete") {
    return { keyframes: DELETE_EXIT, options: { duration: DELETE_EXIT_MS, easing: "cubic-bezier(.35,0,.2,1)", fill: "forwards" } };
  }
  // A MOVE with no replacement in the payload: the same slide-off as the ghost.
  return { keyframes: SLIDE_OFF_RIGHT, options: { duration: SLIDE_OFF_MS, easing: MOVE_EASING, fill: "forwards" } };
}

// The names of the durations that must fit inside one beat, and the move's chain.
// Returns the rules this beat breaks; an empty list means every exit fits.
export function exceedsBeat(beatMs) {
  const broken = [];
  const single = { EXIT_MS, GAP_CLOSE_MS, GROW_IN_MS, SLIDE_OFF_MS };
  for (const [name, ms] of Object.entries(single)) {
    if (!(ms < beatMs)) broken.push(name);
  }
  // A MOVE is the longest thing a beat holds: the slide, then the grow-in.
  if (!(SLIDE_OFF_MS + GROW_IN_MS <= beatMs)) broken.push("SLIDE_OFF_MS + GROW_IN_MS");
  return broken;
}

// The release modules above the board, replaced wholesale on a release state change.
// #current-release plays here, from the signature diff; #last-release is delegated to
// the ReleaseFx router (board/release_fx), which owns its events.
export const RELEASE_FX = { "current-release": "glow", "last-release": "router" };

export const METER_GLOW_MS = 2000;
export const METER_FADE_MS = 400;   // the .studio-team-glow opacity transition (engine-motion.css)

// What one incoming deployments stream means for the effects, from its action and
// target alone (plus, for a remove, the card ids the following streams carry).
//   { kind: "release", routed }  a release-module swap; routed = the router decides
//   { kind: "move-exit" }        a remove whose card is re-added in the same payload
//   { kind: "exit" }             a remove that stands alone (archive, delete, move out)
//   { kind: "pending", action }  any other card action; onAdd reads it back
//   null                         not a board stream the effects touch
export function classifyStream({ action, target, followingCardIds }) {
  const slot = target || "";
  if (RELEASE_FX[slot] && (action === "replace" || action === "update")) {
    return { kind: "release", routed: RELEASE_FX[slot] === "router" };
  }
  if (!slot.startsWith("card-")) return null;
  if (action === "remove") {
    return (followingCardIds || []).includes(slot) ? { kind: "move-exit" } : { kind: "exit" };
  }
  return { kind: "pending", action };
}

// How a freshly patched-in card arrives.
//   null       not a card, or a local drag (its own broadcast echo animates later)
//   "move"     its old self is still leaving: hold it, then grow it in
//   "replace"  an in-place update: a glow pulse
//   "create"   a new card: the full arrival burst
export function arrivalKind({ id, dragging, moving, action }) {
  if (!id || !id.startsWith("card-")) return null;
  if (dragging) return null;
  if (moving) return "move";
  if (action === "replace") return "replace";
  return "create";
}

// Which meters MOVED across a #current-release swap. `before` maps each meter's key
// (repo/phase) to its signature; `after` lists the fresh meters as { key, signature }.
// A changed lane-up (a member added, a repo dropped, the empty state) is not a meter
// tick at all: the keys themselves differ, so this returns null and the caller falls
// back to the card-wide decision.
export function changedMeters(before, after) {
  if (!before || before.size !== after.length) return null;
  const moved = [];
  for (const meter of after) {
    if (!before.has(meter.key)) return null;
    if (before.get(meter.key) !== (meter.signature || "")) moved.push(meter);
  }
  return moved;
}

// What the #current-release swap plays. THREE branches, because the middle one is not
// the complement of the first:
//   a meter moved                         -> "meters" (ring those meters)
//   no meter moved, card signature moved  -> "card"   (new release, stage advance,
//                                                       mascot stamp, member joined)
//   neither moved                         -> "none"
// The third is the common one: the CI ingest upserts on queued AND in_progress AND
// completed, and both pre-completion states render the same, so a queued->in_progress
// delivery re-renders this card byte-identically. It must stay a no-op.
export function releaseSlotEffect({ moved, before, freshSignature }) {
  if (moved && moved.length) return "meters";
  if (!before || (freshSignature || "") !== before.card) return "card";
  return "none";
}

// The meter's identity across a card swap: repo + phase. The phase alone is not
// unique, since every lane draws an "assembling".
export function meterKey(repo, phase) {
  return (repo || "?") + "/" + (phase || "?");
}

// A ghost clone is a picture, not a component: Alpine initialises anything added to
// the document, so these attributes come off before it lands.
export function isDirectiveAttribute(name) {
  return /^(x-|@|:)/.test(name);
}

// ── particles ────────────────────────────────────────────────────────────────
// Each builder returns one particle's inline style, keyframes and timing for the
// card's rect. `rand` is Math.random in the page and a fixed sequence in a test.

// Confetti sits BEHIND the lifted card and shoots from its side edges, alternating
// sides, so the card's centre and its text stay clear.
export function confettiPiece(r, i, rand = Math.random) {
  const side = i % 2 === 0 ? -1 : 1;
  const width = 8 + rand() * 11;
  const height = 7 + rand() * 15;
  const startX = side < 0 ? r.left + 3 + rand() * 10 : r.right - 3 - rand() * 10;
  const startY = r.top + r.height * (0.18 + rand() * 0.64);
  const dx = side * (42 + rand() * 118);
  const dy = (rand() - 0.5) * 136 - 18;
  const spin = side * (160 + rand() * 360);
  return {
    side, startX, startY, dx, dy,
    cssText:
      "position:fixed;left:" + startX + "px;top:" + startY + "px;width:" + width + "px;height:" + height +
      "px;border-radius:3px;pointer-events:none;z-index:20;background:" +
      CONFETTI_COLORS[i % CONFETTI_COLORS.length] + ";box-shadow:0 0 10px rgba(255,255,255,.32);",
    keyframes: [
      { transform: "translate(-50%,-50%) rotate(0deg) scale(.65)", opacity: 0.95 },
      { transform: "translate(calc(-50% + " + dx + "px), calc(-50% + " + dy + "px)) rotate(" + spin + "deg) scale(1)", opacity: 0.85, offset: 0.58 },
      { transform: "translate(calc(-50% + " + (dx * 1.15) + "px), calc(-50% + " + (dy + 36) + "px)) rotate(" + (spin * 1.35) + "deg) scale(.25)", opacity: 0 }
    ],
    options: { duration: 850 + rand() * 500, easing: "cubic-bezier(.18,.78,.2,1)" }
  };
}

// Reviewed is the "smooth sailing" moment: longer mint/cyan ribbons blow out from
// behind the card edges while the card stays in front.
export function gustRibbon(r, i, rand = Math.random) {
  const side = i % 2 === 0 ? -1 : 1;
  const width = 18 + rand() * 30;
  const height = 7 + rand() * 9;
  const startX = side < 0 ? r.left - 5 + rand() * 8 : r.right + 5 - rand() * 8;
  const startY = r.top + r.height * (0.16 + rand() * 0.68);
  const dx = side * (92 + rand() * 176);
  const dy = -50 + rand() * 112;
  const spin = side * (90 + rand() * 220);
  return {
    side, startX, startY, dx, dy,
    cssText:
      "position:fixed;left:" + startX + "px;top:" + startY + "px;width:" + width + "px;height:" + height +
      "px;border-radius:9999px;pointer-events:none;z-index:35;background:" +
      REVIEWED_GUST_COLORS[i % REVIEWED_GUST_COLORS.length] + ";box-shadow:0 0 16px rgba(103,232,249,.58),0 0 28px rgba(250,204,21,.22);",
    keyframes: [
      { transform: "translate(-50%,-50%) rotate(" + (-side * 8) + "deg) scaleX(.72)", opacity: 1 },
      { transform: "translate(calc(-50% + " + dx + "px), calc(-50% + " + dy + "px)) rotate(" + spin + "deg) scaleX(1.16)", opacity: 0.9, offset: 0.48 },
      { transform: "translate(calc(-50% + " + (dx * 1.18) + "px), calc(-50% + " + (dy + 24) + "px)) rotate(" + (spin * 1.25) + "deg) scaleX(.22)", opacity: 0 }
    ],
    options: { duration: 920 + rand() * 460, easing: "cubic-bezier(.16,.84,.24,1)" }
  };
}

// The reviewed wake: two soft rings that swell out from the card's centre.
export function wakeRing(r, i) {
  const padX = 20 + i * 18;
  const padY = 14 + i * 12;
  return {
    cssText:
      "position:fixed;left:" + (r.left + r.width / 2) + "px;top:" + (r.top + r.height / 2) + "px;width:" + (r.width + padX) +
      "px;height:" + (r.height + padY) + "px;border-radius:14px;pointer-events:none;z-index:35;border:2px solid rgba(103,232,249,.72);" +
      "background:radial-gradient(circle at center, rgba(94,234,212,.2), rgba(103,232,249,.08) 45%, rgba(250,204,21,.12) 68%, transparent 72%);" +
      "box-shadow:0 0 24px rgba(103,232,249,.42),0 0 42px rgba(250,204,21,.2);",
    keyframes: [
      { transform: "translate(-50%,-50%) scale(.72)", opacity: 0.78 },
      { transform: "translate(-50%,-50%) scale(1.08)", opacity: 0.54, offset: 0.48 },
      { transform: "translate(-50%,-50%) scale(1.34)", opacity: 0 }
    ],
    options: { duration: 760 + i * 180, easing: "cubic-bezier(.16,.84,.24,1)" }
  };
}

// The archive mist: blurred puffs that rise off the card and fade inside the exit.
export function mistPuff(r, i, rand = Math.random) {
  const size = 14 + rand() * 30;
  const startX = r.left + r.width * (0.1 + rand() * 0.8);
  const startY = r.top + r.height * (0.12 + rand() * 0.76);
  const dx = (rand() - 0.5) * 120;
  const dy = (rand() - 0.68) * 100;
  return {
    startX, startY, dx, dy,
    cssText:
      "position:fixed;left:" + startX + "px;top:" + startY + "px;width:" + size + "px;height:" + size +
      "px;border-radius:9999px;pointer-events:none;z-index:45;background:" +
      MIST_COLORS[i % MIST_COLORS.length] + ";filter:blur(" + (2 + rand() * 4) + "px);",
    keyframes: [
      { transform: "translate(-50%,-50%) scale(.35)", opacity: 0 },
      { transform: "translate(calc(-50% + " + (dx * 0.5) + "px), calc(-50% + " + (dy * 0.5) + "px)) scale(1)", opacity: 0.72, offset: 0.32 },
      { transform: "translate(calc(-50% + " + dx + "px), calc(-50% + " + dy + "px)) scale(1.8)", opacity: 0 }
    ],
    options: { duration: EXIT_MS + rand() * 160, easing: "ease-out" }
  };
}
