// [unit] logo_grid: the math behind the landing's logo grid backdrop (task
// logo-grid-backdrop). The grid covers its box, no tile touches a copy of
// itself, the light falls off smoothly with distance, rises fast and fades
// slowly (the trail), and the wandering light stays inside the box.
import { test } from "node:test";
import assert from "node:assert/strict";

import { CELL, animates, layoutChanged, RADIUS, cellCentre, intensity, layout, rowStep, settle, tileIndex, wander } from "../../app/javascript/logo_grid.js";

test("layout covers the box with one spare row and column", () => {
  assert.deepEqual(layout(920, 400, 92), { cols: 11, rows: 6, cell: 92 });
  assert.deepEqual(layout(0, 400), { cols: 0, rows: 0, cell: CELL });
  assert.deepEqual(layout(NaN, 400), { cols: 0, rows: 0, cell: CELL });
  // The last centre reaches past the far edges, so no strip is left bare.
  const { cols, rows } = layout(1000, 500, 92);
  assert.ok(cellCentre(0, cols - 1, 92).x >= 1000 - 92 / 2);
  assert.ok(cellCentre(rows - 1, 0, 92).y >= 500);
});

test("odd rows sit half a cell over (the brick offset)", () => {
  assert.equal(cellCentre(1, 0, 100).x - cellCentre(0, 0, 100).x, 50);
  assert.equal(cellCentre(2, 0, 100).x, cellCentre(0, 0, 100).x);
  assert.equal(cellCentre(3, 2, 100).y, 300);
});

test("no tile touches a copy of itself, for every tile count from 4 to 40", () => {
  for (let count = 4; count <= 40; count += 1) {
    const step = rowStep(count);
    for (let r = 1; r < 12; r += 1) {
      for (let c = 1; c < 20; c += 1) {
        const here = tileIndex(r, c, count, step);
        assert.ok(here >= 0 && here < count);
        assert.notEqual(here, tileIndex(r, c - 1, count, step), `count ${count}: left neighbour`);
        // In a brick grid the row above touches up to three tiles.
        for (const dc of [-1, 0, 1]) {
          assert.notEqual(here, tileIndex(r - 1, c + dc, count, step), `count ${count}: row above, ${dc}`);
        }
      }
    }
  }
});

test("every tile appears in a row (the step never skips one)", () => {
  const count = 13;
  const seen = new Set(Array.from({ length: count }, (_, c) => tileIndex(4, c, count)));
  assert.equal(seen.size, count);
  assert.equal(tileIndex(0, 0, 0), -1);
});

test("light is full at the point, gone at the radius, and falls off smoothly", () => {
  assert.equal(intensity(0), 1);
  assert.equal(intensity(RADIUS), 0);
  assert.equal(intensity(RADIUS * 2), 0);
  assert.equal(intensity(RADIUS / 2), 0.5);
  let prev = 1;
  for (let d = 10; d < RADIUS; d += 10) {
    const v = intensity(d);
    assert.ok(v < prev, `falls at ${d}`);
    prev = v;
  }
  assert.equal(intensity(10, 0), 0);
});

test("a tile lights fast and fades slowly, then rests exactly at its target", () => {
  const up = settle(0, 1, 70);
  const down = settle(1, 0, 70);
  assert.ok(up > 0.6, `rises most of the way in one rise time: ${up}`);
  assert.ok(down > 0.85, `keeps most of its light after the same time: ${down}`);
  // After enough frames it rests at the target, so the loop has nothing to redraw.
  let lit = 1;
  for (let i = 0; i < 400; i += 1) lit = settle(lit, 0, 16);
  assert.equal(lit, 0);
  let on = 0;
  for (let i = 0; i < 100; i += 1) on = settle(on, 0.4, 16);
  assert.equal(on, 0.4);
  // A frame with no time changes nothing.
  assert.equal(settle(0.5, 0, 0), 0.5);
});

test("the wandering light stays inside the box, away from the edges", () => {
  for (let t = 0; t < 32000; t += 250) {
    const { x, y } = wander(t, 1000, 400);
    assert.ok(x >= 100 && x <= 900, `x ${x} at ${t}`);
    assert.ok(y >= 60 && y <= 340, `y ${y} at ${t}`);
  }
});

test("reduced motion gets a still grid; everyone else, phones too, gets the loop", () => {
  const media = (reduce) => (q) => ({ matches: q === "(prefers-reduced-motion: reduce)" && reduce });
  assert.equal(animates(media(true)), false);
  assert.equal(animates(media(false)), true);
  assert.equal(animates(null), true);
  assert.equal(animates(() => { throw new Error("no media"); }), true);
});

test("the grid rebuilds only when its layout changed", () => {
  const built = { cols: 11, rows: 6, cell: 92, count: 18 };
  assert.equal(layoutChanged(null, built), true, "the first build always runs");
  assert.equal(layoutChanged(built, { ...built }), false, "the start-up resize event changes nothing");
  assert.equal(layoutChanged(built, { ...built, cols: 12 }), true);
  assert.equal(layoutChanged(built, { ...built, rows: 7 }), true);
  assert.equal(layoutChanged(built, { ...built, cell: 72 }), true, "the phone pitch");
  assert.equal(layoutChanged(built, { ...built, count: 19 }), true);
});
