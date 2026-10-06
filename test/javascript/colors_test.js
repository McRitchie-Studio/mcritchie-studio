// [unit] The board effects' colour helpers (board/colors).
import { test } from "node:test";
import assert from "node:assert/strict";

import { hexToRgb, paintableColor } from "board/colors";

test("a six-digit hex becomes the space-separated triple rgb(var() / a) takes", () => {
  assert.equal(hexToRgb("#78C850"), "120 200 80");
  assert.equal(hexToRgb("78c850"), "120 200 80");
  assert.equal(hexToRgb("#000000"), "0 0 0");
});

test("anything else is unparseable", () => {
  for (const value of ["", null, undefined, "#fff", "#78C85", "rgb(1, 2, 3)", "#78C850 "]) {
    assert.equal(hexToRgb(value), null, String(value));
  }
});

// A stand-in for a 1x1 canvas: it "parses" the colours it knows and paints their
// alpha; an unknown value leaves fillStyle on the previous (opaque) sentinel, as a
// real canvas does.
function fakeCanvas(alphas) {
  let fill = null;
  let painted = 0;
  return {
    set fillStyle(value) { if (value in alphas) fill = value; },
    get fillStyle() { return fill; },
    clearRect() { painted = 0; },
    fillRect() { painted = alphas[fill]; },
    getImageData() { return { data: [0, 0, 0, painted] }; }
  };
}

test("a colour that paints with any alpha is returned as given", () => {
  const ctx = fakeCanvas({ "#000000": 255, "oklch(0.7 0.15 160)": 255, "oklch(0.7 0.15 160 / 0.2)": 51 });
  assert.equal(paintableColor("oklch(0.7 0.15 160)", ctx), "oklch(0.7 0.15 160)");
  assert.equal(paintableColor("oklch(0.7 0.15 160 / 0.2)", ctx), "oklch(0.7 0.15 160 / 0.2)");
});

test("a colour that paints nothing is null, whatever space it is spelled in", () => {
  const ctx = fakeCanvas({ "#000000": 255, "oklch(0.7 0.15 160 / 0)": 0, "rgba(0, 0, 0, 0)": 0 });
  assert.equal(paintableColor("oklch(0.7 0.15 160 / 0)", ctx), null);
  assert.equal(paintableColor("rgba(0, 0, 0, 0)", ctx), null);
});

test("an empty value is null without touching the canvas", () => {
  assert.equal(paintableColor("", null), null);
  assert.equal(paintableColor(undefined, null), null);
});

test("a value the canvas cannot parse paints the opaque sentinel and is returned", () => {
  const ctx = fakeCanvas({ "#000000": 255 });
  assert.equal(paintableColor("future-space(1 2 3 / 0)", ctx), "future-space(1 2 3 / 0)");
});
