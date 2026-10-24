// [unit] agent_chat: the thinking/typing swap (task chat-thinking-versus-typing).
// A pulse redraws the indicator, so the phase the old one showed is carried onto
// the new one for one frame and then let go (the CSS crossfades the change); the
// same phase is left alone; and each redraw's motion is put at the page clock's
// place in the beat, so it never restarts. Driven with stand-in elements.
import { test } from "node:test";
import assert from "node:assert/strict";

import { BEAT_MS, carryPhase, indicatorKey, phasesIn, syncDelay } from "../../app/javascript/agent_chat.js";

function indicator(phase, slotId = "cto-chat-typing") {
  const slot = { id: slotId, closest: () => slot };
  return { dataset: { phase }, offsetWidth: 120, parentElement: slot };
}

function frames() {
  const queued = [];
  const frame = (fn) => queued.push(fn);
  frame.flush = () => queued.splice(0).forEach((fn) => fn());
  return frame;
}

test("thinking to typing shows thinking for one frame, then typing", () => {
  const next = indicator("typing");
  const frame = frames();

  assert.equal(carryPhase(next, "thinking", frame), true);
  assert.equal(next.dataset.phase, "thinking", "the old look first, so the transition has somewhere to start");
  frame.flush();
  assert.equal(next.dataset.phase, "typing");
});

test("the same phase, or none before, is left as drawn", () => {
  const frame = frames();
  const same = indicator("thinking");
  assert.equal(carryPhase(same, "thinking", frame), false);
  assert.equal(same.dataset.phase, "thinking");

  const first = indicator("thinking");
  assert.equal(carryPhase(first, undefined, frame), false);
  frame.flush();
  assert.equal(first.dataset.phase, "thinking");
});

test("indicators are matched across a redraw by their slot or turn", () => {
  const cto = indicator("thinking", "cto-chat-typing");
  const build = indicator("typing", "build-turn-7");
  assert.equal(indicatorKey(cto), "cto-chat-typing");
  assert.equal(indicatorKey(build), "build-turn-7");

  const root = { querySelectorAll: () => [cto, build] };
  assert.deepEqual([...phasesIn(root)], [["cto-chat-typing", "thinking"], ["build-turn-7", "typing"]]);
  assert.equal(phasesIn(null).size, 0);
});

test("the sync delay is the clock's place in the beat, as a negative CSS time", () => {
  assert.equal(syncDelay(BEAT_MS * 1000 + 600), "-600ms");
  assert.equal(syncDelay(BEAT_MS * 3), "-0ms");
});
