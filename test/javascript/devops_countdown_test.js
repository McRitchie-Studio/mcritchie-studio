// [unit] devops_countdown: the app chat status card's live pill countdown (task
// live-build-countdown). countdownClock must match AppDevopsStages::Eta.clock,
// which paints the first value; tick rewrites every countdown span on the page
// from its deadline, and never goes negative.
import { test } from "node:test";
import assert from "node:assert/strict";

import { ANY_MINUTE, countdownClock, tick } from "../../app/javascript/devops_countdown.js";

test("MM:SS under an hour, H:MM:SS from an hour up, seconds floored", () => {
  assert.equal(countdownClock(348), "05:48");
  assert.equal(countdownClock(1.9), "00:01");
  assert.equal(countdownClock(3599), "59:59");
  assert.equal(countdownClock(3600), "1:00:00");
  assert.equal(countdownClock(3723), "1:02:03");
  assert.equal(countdownClock(26 * 3600), "26:00:00");
});

test("at or past zero it reads Any minute now, never a negative", () => {
  assert.equal(ANY_MINUTE, "Any minute now");
  [ 0, 0.5, -1, -3600, NaN ].forEach((seconds) => assert.equal(countdownClock(seconds), ANY_MINUTE));
});

test("tick counts each span down from its deadline, then holds at Any minute now", () => {
  const deadline = Date.parse("2026-10-21T04:00:00Z");
  const span = { dataset: { deadline: "2026-10-21T04:00:00Z", etaKind: "left" }, textContent: "06:00" };
  const bad = { dataset: { deadline: "nope", etaKind: "left" }, textContent: "keep" };
  const root = { querySelectorAll: (sel) => (sel === "[data-devops-countdown]" ? [ span, bad ] : []) };

  tick(root, deadline - 348 * 1000);
  assert.equal(span.textContent, "05:48");
  tick(root, deadline - 347 * 1000);
  assert.equal(span.textContent, "05:47", "one second later, one second less");
  assert.equal(span.dataset.etaKind, "left");

  tick(root, deadline - 400);
  assert.equal(span.textContent, ANY_MINUTE, "under a second left reads as no time left");
  assert.equal(span.dataset.etaKind, "long");
  tick(root, deadline + 90 * 1000);
  assert.equal(span.textContent, ANY_MINUTE, "past the deadline it never counts up or goes negative");
  assert.equal(bad.textContent, "keep", "a span with no deadline is left alone");
});
