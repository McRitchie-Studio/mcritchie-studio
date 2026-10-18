// [unit] gallery_motion: when a /build gallery card plays its hover loop, and
// what play and stop do to the video. Run against stand-in elements.
import { test } from "node:test";
import assert from "node:assert/strict";

import { shouldPlay, play, stop } from "../../app/javascript/gallery_motion.js";

test("a mouse plays the loop; a touch or pen does not", () => {
  assert.equal(shouldPlay({ kind: "pointer", pointerType: "mouse", reducedMotion: false }), true);
  assert.equal(shouldPlay({ kind: "pointer", pointerType: "touch", reducedMotion: false }), false);
  assert.equal(shouldPlay({ kind: "pointer", pointerType: "pen", reducedMotion: false }), false);
});

test("keyboard focus plays it; a click's focus does not", () => {
  assert.equal(shouldPlay({ kind: "focus", focusVisible: true, reducedMotion: false }), true);
  assert.equal(shouldPlay({ kind: "focus", focusVisible: false, reducedMotion: false }), false);
});

test("reduced motion keeps the still, whatever the input", () => {
  assert.equal(shouldPlay({ kind: "pointer", pointerType: "mouse", reducedMotion: true }), false);
  assert.equal(shouldPlay({ kind: "focus", focusVisible: true, reducedMotion: true }), false);
});

function card() {
  const video = {
    plays: 0, paused: true, currentTime: 2.4, attributes: { "data-playing": "" },
    play() { this.plays += 1; this.paused = false; return Promise.reject(new Error("blocked")); },
    pause() { this.paused = true; },
    removeAttribute(name) { delete this.attributes[name]; },
  };
  return { video, querySelector: () => video };
}

test("play asks the video to play and swallows a refused play", async () => {
  const c = card();
  play(c);
  assert.equal(c.video.plays, 1);
  await new Promise((resolve) => setImmediate(resolve)); // an unhandled rejection would fail the run
});

test("stop pauses, rewinds and clears data-playing, so the still shows again", () => {
  const c = card();
  stop(c);
  assert.equal(c.video.paused, true);
  assert.equal(c.video.currentTime, 0);
  assert.deepEqual(c.video.attributes, {});
});

test("a card with no loop is left alone", () => {
  assert.doesNotThrow(() => { play({ querySelector: () => null }); stop({ querySelector: () => null }); });
});
