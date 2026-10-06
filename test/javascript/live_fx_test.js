// [unit] The /deployments live effects' decisions (board/live_fx): which stream plays
// what, which meters moved, what a release swap earns, the beat rule, and the shapes
// of the confetti, gusts and mist.
import { test } from "node:test";
import assert from "node:assert/strict";

import {
  classifyStream, arrivalKind, changedMeters, releaseSlotEffect, meterKey, isDirectiveAttribute,
  exceedsBeat, exitAnimation, confettiPiece, gustRibbon, mistPuff, wakeRing,
  EXIT_MS, SLIDE_OFF_MS, SLIDE_OFF_RIGHT, ARCHIVE_EXIT, DELETE_EXIT, CONFETTI_COLORS, MIST_COLORS
} from "board/live_fx";

// ── the stream classifier ────────────────────────────────────────────────────

test("a release-module replace is routed for #last-release and diffed for #current-release", () => {
  assert.deepEqual(classifyStream({ action: "replace", target: "last-release" }), { kind: "release", routed: true });
  assert.deepEqual(classifyStream({ action: "update", target: "current-release" }), { kind: "release", routed: false });
});

test("a release module removed or appended is not an effect", () => {
  assert.equal(classifyStream({ action: "remove", target: "current-release" }), null);
  assert.equal(classifyStream({ action: "append", target: "last-release" }), null);
});

test("streams for anything but a card or a release module are ignored", () => {
  assert.equal(classifyStream({ action: "replace", target: "app-ladder" }), null);
  assert.equal(classifyStream({ action: "remove", target: "" }), null);
  assert.equal(classifyStream({ action: "remove", target: undefined }), null);
});

test("a card remove is a move exit only when the same card follows in the payload", () => {
  assert.deepEqual(
    classifyStream({ action: "remove", target: "card-a", followingCardIds: ["card-b", "card-a"] }),
    { kind: "move-exit" }
  );
  assert.deepEqual(classifyStream({ action: "remove", target: "card-a", followingCardIds: ["card-b"] }), { kind: "exit" });
  assert.deepEqual(classifyStream({ action: "remove", target: "card-a" }), { kind: "exit" });
});

test("any other card action is remembered for the arrival", () => {
  assert.deepEqual(classifyStream({ action: "replace", target: "card-a" }), { kind: "pending", action: "replace" });
  assert.deepEqual(classifyStream({ action: "prepend", target: "card-a" }), { kind: "pending", action: "prepend" });
});

// ── arrivals ─────────────────────────────────────────────────────────────────

test("an arrival is a move while its old self is leaving, else a replace or a create", () => {
  assert.equal(arrivalKind({ id: "card-a", moving: true, action: "prepend" }), "move");
  assert.equal(arrivalKind({ id: "card-a", moving: false, action: "replace" }), "replace");
  assert.equal(arrivalKind({ id: "card-a", moving: false, action: "prepend" }), "create");
  assert.equal(arrivalKind({ id: "card-a", moving: false, action: undefined }), "create");
});

test("a local drag and a non-card node never animate", () => {
  assert.equal(arrivalKind({ id: "card-a", dragging: true, moving: true }), null);
  assert.equal(arrivalKind({ id: "dropzone-shipped" }), null);
  assert.equal(arrivalKind({ id: "" }), null);
});

// ── the Next Release meters ──────────────────────────────────────────────────

const before = (entries) => new Map(entries);

test("only the meters whose signature changed are returned", () => {
  const was = before([["hub/assembling", "3/9"], ["engine/assembling", "1/4"]]);
  const now = [{ key: "hub/assembling", signature: "4/9" }, { key: "engine/assembling", signature: "1/4" }];
  assert.deepEqual(changedMeters(was, now), [{ key: "hub/assembling", signature: "4/9" }]);
});

test("a byte-identical re-render moves no meter", () => {
  const was = before([["hub/assembling", "3/9"]]);
  assert.deepEqual(changedMeters(was, [{ key: "hub/assembling", signature: "3/9" }]), []);
});

test("a changed lane-up is not a tick: a member added, a repo swapped, or no snapshot", () => {
  const was = before([["hub/assembling", "3/9"]]);
  assert.equal(changedMeters(was, [{ key: "hub/assembling", signature: "3/9" }, { key: "engine/assembling", signature: "" }]), null);
  assert.equal(changedMeters(was, [{ key: "engine/assembling", signature: "3/9" }]), null);
  assert.equal(changedMeters(null, []), null);
});

test("a missing signature reads as empty on both sides", () => {
  const was = before([["hub/qa", ""]]);
  assert.deepEqual(changedMeters(was, [{ key: "hub/qa", signature: undefined }]), []);
});

test("the meter key is repo and phase, with ? for a missing part", () => {
  assert.equal(meterKey("hub", "assembling"), "hub/assembling");
  assert.equal(meterKey(undefined, "qa"), "?/qa");
  assert.equal(meterKey("hub", ""), "hub/?");
});

test("a swap rings meters, else flashes the card only when its signature moved, else does nothing", () => {
  const snap = { card: "rel-1:assembling" };
  assert.equal(releaseSlotEffect({ moved: [{ key: "hub/qa" }], before: snap, freshSignature: "rel-1:assembling" }), "meters");
  assert.equal(releaseSlotEffect({ moved: [], before: snap, freshSignature: "rel-1:qa" }), "card");
  assert.equal(releaseSlotEffect({ moved: null, before: snap, freshSignature: "rel-2:assembling" }), "card");
  assert.equal(releaseSlotEffect({ moved: [], before: snap, freshSignature: "rel-1:assembling" }), "none");
  assert.equal(releaseSlotEffect({ moved: null, before: snap, freshSignature: "rel-1:assembling" }), "none");
});

test("a swap with no snapshot flashes the card", () => {
  assert.equal(releaseSlotEffect({ moved: null, before: null, freshSignature: "" }), "card");
});

// ── the ghost ────────────────────────────────────────────────────────────────

test("Alpine directives are scrubbed off a ghost, plain attributes are kept", () => {
  for (const name of ["x-data", "x-show", "@click", ":class"]) assert.equal(isDirectiveAttribute(name), true, name);
  for (const name of ["class", "data-stage", "style", "aria-label"]) assert.equal(isDirectiveAttribute(name), false, name);
});

// ── the beat ─────────────────────────────────────────────────────────────────

test("every exit fits a beat longer than the move's slide plus grow-in", () => {
  assert.deepEqual(exceedsBeat(800), []);
  assert.deepEqual(exceedsBeat(600), []);
});

test("a beat shorter than the move chain names the chain it breaks", () => {
  assert.deepEqual(exceedsBeat(599), ["SLIDE_OFF_MS + GROW_IN_MS"]);
});

test("a beat no longer than an exit names every exit that outruns it", () => {
  assert.deepEqual(exceedsBeat(EXIT_MS), ["EXIT_MS", "SLIDE_OFF_MS + GROW_IN_MS"]);
  assert.ok(exceedsBeat(300).includes("SLIDE_OFF_MS"));
});

test("an archive dissolves, a delete fades out, and a move slides off right", () => {
  assert.equal(exitAnimation("archive").keyframes, ARCHIVE_EXIT);
  assert.equal(exitAnimation("archive").options.duration, EXIT_MS);
  assert.equal(exitAnimation("delete").keyframes, DELETE_EXIT);
  assert.equal(exitAnimation(undefined).keyframes, SLIDE_OFF_RIGHT);
  assert.equal(exitAnimation(undefined).options.duration, SLIDE_OFF_MS);
  assert.equal(ARCHIVE_EXIT.at(-1).filter, "blur(9px)");
  assert.equal(SLIDE_OFF_RIGHT.at(-1).transform, "translateX(150px) scale(.95)");
});

// ── particles ────────────────────────────────────────────────────────────────

const rect = { left: 100, right: 300, top: 50, width: 200, height: 80 };
const fixed = (value) => () => value;

test("confetti alternates sides and starts at the card's side edges", () => {
  const left = confettiPiece(rect, 0, fixed(0));
  const right = confettiPiece(rect, 1, fixed(0));
  assert.equal(left.side, -1);
  assert.equal(right.side, 1);
  assert.equal(left.startX, rect.left + 3);
  assert.equal(right.startX, rect.right - 3);
  assert.ok(confettiPiece(rect, 0, fixed(0.999)).startX < rect.left + 14);
  assert.ok(confettiPiece(rect, 1, fixed(0.999)).startX > rect.right - 14);
});

test("confetti flies outward between 42px and 160px, behind the lifted card", () => {
  assert.equal(confettiPiece(rect, 0, fixed(0)).dx, -42);
  assert.equal(confettiPiece(rect, 1, fixed(0)).dx, 42);
  assert.ok(Math.abs(confettiPiece(rect, 1, fixed(1)).dx - 160) < 1e-9);
  const piece = confettiPiece(rect, 2, fixed(0.5));
  assert.match(piece.cssText, /z-index:20;/);
  assert.match(piece.cssText, new RegExp("background:" + CONFETTI_COLORS[2]));
  assert.equal(piece.keyframes.at(-1).opacity, 0);
});

test("confetti starts inside the card's middle band, clear of its top and bottom", () => {
  assert.equal(confettiPiece(rect, 0, fixed(0)).startY, rect.top + rect.height * 0.18);
  assert.ok(confettiPiece(rect, 0, fixed(1)).startY <= rect.top + rect.height * 0.82 + 1e-9);
});

test("the reviewed gust blows out past the card edges, over it, from both sides", () => {
  const left = gustRibbon(rect, 0, fixed(0));
  const right = gustRibbon(rect, 1, fixed(0));
  assert.ok(left.startX < rect.left && right.startX > rect.right);
  assert.ok(left.dx <= -92 && right.dx >= 92);
  assert.match(left.cssText, /z-index:35;/);
});

test("the wake rings swell from the card's centre, the second one wider", () => {
  const first = wakeRing(rect, 0);
  const second = wakeRing(rect, 1);
  assert.match(first.cssText, /left:200px;top:90px;width:220px/);
  assert.match(second.cssText, /width:238px/);
  assert.ok(second.options.duration > first.options.duration);
});

test("the archive mist stays over the card and ends inside the exit plus its tail", () => {
  const puff = mistPuff(rect, 5, fixed(0.5));
  assert.ok(puff.startX > rect.left && puff.startX < rect.right);
  assert.match(puff.cssText, /z-index:45;/);
  assert.match(puff.cssText, new RegExp("background:" + MIST_COLORS[1].replace(/[().]/g, "\\$&")));
  assert.equal(puff.options.duration, EXIT_MS + 80);
});
