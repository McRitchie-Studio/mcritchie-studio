// [unit] typing_placeholder: /build's first chat box types example ideas into
// its placeholder, and the timer behind it runs only while such a box is on the
// page. Driven with a stand-in page, timer and clock.
import { test } from "node:test";
import assert from "node:assert/strict";

import { typingTicker, step, TICK_MS } from "../../app/javascript/typing_placeholder.js";

function box(examples = ["Ab", "Cd"]) {
  return { dataset: { typingPlaceholder: JSON.stringify(examples) }, placeholder: "" };
}

function harness(page) {
  const timers = [];
  let clock = 0;
  const ticker = typingTicker({
    boxes: () => page.boxes,
    now: () => clock,
    setTimer: (fn, every) => { timers.push({ fn, every, cleared: false }); return timers.length; },
    clearTimer: (id) => { timers[id - 1].cleared = true; },
  });
  return { ticker, timers, advance: (ms) => { clock += ms; } };
}

test("a page without the box starts no timer", () => {
  const { ticker, timers } = harness({ boxes: [] });
  ticker.start();
  assert.equal(timers.length, 0);
  assert.equal(ticker.running, false);
});

test("on /build the timer runs, once, and types the first example", () => {
  const page = { boxes: [box()] };
  const { ticker, timers, advance } = harness(page);
  ticker.start();
  ticker.start();
  assert.equal(timers.length, 1, "a second turbo:load does not stack a second timer");
  assert.equal(timers[0].every, TICK_MS);
  ticker.tick();
  assert.equal(page.boxes[0].placeholder, "A");
  advance(50);
  ticker.tick();
  assert.equal(page.boxes[0].placeholder, "Ab");
});

test("the timer stops itself once the box leaves the page, and starts again when it returns", () => {
  const page = { boxes: [box()] };
  const { ticker, timers } = harness(page);
  ticker.start();
  page.boxes = [];
  ticker.tick();
  assert.equal(ticker.running, false);
  assert.equal(timers[0].cleared, true, "the interval is cleared, not left idling");
  page.boxes = [box()];
  ticker.start();
  assert.equal(ticker.running, true);
  assert.equal(timers.length, 2);
});

test("a hidden tab keeps the timer but types nothing", () => {
  const page = { boxes: [box()] };
  const ticker = typingTicker({ boxes: () => page.boxes, hidden: () => true, setTimer: () => 1, clearTimer: () => {} });
  ticker.start();
  ticker.tick();
  assert.equal(page.boxes[0].placeholder, "");
  assert.equal(ticker.running, true);
});

test("reduced motion shows the first example, still", () => {
  const b = box(["First idea", "Second"]);
  const state = { index: 0, length: 0, erasing: false, next: 0 };
  step(b, state, 0, true);
  step(b, state, 10000, true);
  assert.equal(b.placeholder, "First idea");
});

test("it types, holds, erases and moves to the next example", () => {
  const b = box(["Ab", "Cd"]);
  const state = { index: 0, length: 0, erasing: false, next: 0 };
  let now = 0;
  const seen = [];
  for (let i = 0; i < 400 && state.index < 1; i += 1) { step(b, state, now, false); seen.push(b.placeholder); now += 25; }
  assert.ok(seen.includes("Ab"), "typed in full");
  assert.equal(state.index, 1, "then the next example");
  assert.equal(b.placeholder, "");
});
