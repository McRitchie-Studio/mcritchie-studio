// [unit] logo_motion_parts: how the Motion tab splits a kit logo's SVG into the parts a preset moves, and the
// arithmetic the presets share (task logo-motion-presets). The transforms are the ones Logos::NavbarLogo and
// Logos::StackedLogo write: a Navbar Logo's letters at scale 150, a Stacked Logo's name at 120 and its small line at 40.
import { test } from "node:test";
import assert from "node:assert/strict";

import { centreOffset, chooseTone, fitBox, layoutOf, letterDeltas, partRole, scrubTime, scrubValue, seeded, subpaths, tint, translateOf, withAlpha }
  from "../../app/javascript/logo_motion_parts.js";

test("a letter at scale 90 or more is the name, the rest the small line", () => {
  assert.equal(partRole("translate(418.15,225.00) scale(150.0000)"), "name");
  assert.equal(partRole("translate(-12.06,787.06) scale(120.0000)"), "name");
  assert.equal(partRole("translate(192.75,907.06) scale(40.0000)"), "small");
  assert.equal(partRole("translate(1,2) scale(90)"), "name");
  assert.equal(partRole(null), "small");
});

test("a transform's translate, with or without a y, and none as 0, 0", () => {
  assert.deepEqual(translateOf("translate(-12.06,787.06) scale(120.0000)"), { x: -12.06, y: 787.06 });
  assert.deepEqual(translateOf("translate(127.88 0)"), { x: 127.88, y: 0 });
  assert.deepEqual(translateOf("translate(5)"), { x: 5, y: 0 });
  assert.deepEqual(translateOf("scale(0.5)"), { x: 0, y: 0 });
});

test("a path's subpaths split at each absolute moveto", () => {
  assert.deepEqual(subpaths("M0,0 L1,1 Z M2,2 L3,3 Z"), ["M0,0 L1,1 Z", "M2,2 L3,3 Z"]);
  assert.deepEqual(subpaths(""), []);
});

test("the tone follows the hub theme, and the watermark wins when it is all the page carries", () => {
  assert.equal(chooseTone(["light", "dark"], true), "dark");
  assert.equal(chooseTone(["light", "dark"], false), "light");
  assert.equal(chooseTone(["watermark"], false), "watermark");
});

test("a logo fits the stage by whichever share binds first", () => {
  assert.deepEqual(fitBox({ width: 500, height: 500 }, { width: 1000, height: 1000 }), { width: 310, height: 310 });
  const wide = fitBox({ width: 800, height: 450 }, { width: 2500, height: 300 });
  assert.equal(Math.round(wide.width), 608);
  assert.ok(wide.height < 450 * 0.62);
});

test("the icon beside the name is a navbar layout, above it a stacked one", () => {
  assert.equal(layoutOf({ x: 0, width: 300 }, { x: 340, width: 2000 }), "navbar");
  assert.equal(layoutOf({ x: 300, width: 400 }, { x: 0, width: 960 }), "stacked");
  assert.equal(layoutOf({ x: 0, width: 300 }, null), "stacked");
});

test("Weight flick moves each letter from the thin layout, centred in the kit's viewBox, to the kit's own place", () => {
  const offset = centreOffset({ x: 0, y: 0, width: 1800, height: 300 }, { x: 0, y: 0, width: 2000, height: 300 });
  assert.deepEqual(offset, { x: 100, y: 0 });
  assert.deepEqual(letterDeltas([{ x: 400, y: 225 }, { x: 520, y: 225 }], [{ x: 410, y: 225 }, { x: 560, y: 225 }], offset),
                   [{ x: 90, y: 0 }, { x: 60, y: 0 }]);
  assert.equal(letterDeltas([{ x: 0, y: 0 }], [], offset), null, "different letters cannot morph");
});

test("colour helpers: a tint toward white and the hub's translucent rgb form", () => {
  assert.equal(tint("#000000", 0.5), "#808080");
  assert.equal(tint("#4BAF50", 0), "#4BAF50");
  assert.equal(withAlpha("#F08A5A", 0.7), "rgb(240 138 90 / 0.7)");
});

test("the seeded source repeats, so every replay draws the same shower", () => {
  const a = seeded(7);
  const b = seeded(7);
  const first = [a(), a(0, 10), a(-1, 1)];
  assert.deepEqual([b(), b(0, 10), b(-1, 1)], first);
  assert.ok(first.every((value) => Number.isFinite(value)));
});

test("the scrubber maps time to 0..1000 and back", () => {
  assert.equal(scrubValue(1.5, 3), 500);
  assert.equal(scrubValue(1, 0), 0);
  assert.equal(scrubTime(250, 4), 1);
});
