// [unit] devops_countdown: the app chat status card's live pill countdown (task
// live-build-countdown). countdownClock must match AppDevopsStages::Eta.clock,
// which paints the first value; tick rewrites every countdown span on the page
// from its deadline, and never goes negative.
import { test } from "node:test";
import assert from "node:assert/strict";

import { ANY_MINUTE, countdownClock, overLabel, tick } from "../../app/javascript/devops_countdown.js";

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

// The /deployments DevOps hero (task devops-card-counts-down-to-ship): counts down to
// the estimated landing, then counts the overrun UP rather than holding at zero.
test("overLabel speaks the stage vocabulary: <1m, 12m, 1h, 1h 5m", () => {
  assert.equal(overLabel(0), "<1m");
  assert.equal(overLabel(59), "<1m");
  assert.equal(overLabel(12 * 60 + 30), "12m");
  assert.equal(overLabel(3600), "1h");
  assert.equal(overLabel(3600 + 5 * 60), "1h 5m");
});

test("a data-countdown-over span counts down, then reads +Xm over and is marked over", () => {
  const deadline = Date.parse("2026-10-28T20:45:00Z");
  const hero = { dataset: { deadline: "2026-10-28T20:45:00Z", etaKind: "left", countdownOver: "" }, textContent: "" };
  const root = { querySelectorAll: () => [ hero ] };

  tick(root, deadline - 3723 * 1000);
  assert.equal(hero.textContent, "1:02:03");
  assert.equal(hero.dataset.etaKind, "left");

  tick(root, deadline + 12 * 60 * 1000);
  assert.equal(hero.textContent, "+12m over", "past the estimate it says how far over");
  assert.equal(hero.dataset.etaKind, "over");
});

test("a data-countdown-over span's kind follows the clock both ways: the warning ink never outlives the overrun", () => {
  const deadline = Date.parse("2026-10-28T20:45:00Z");
  const hero = { dataset: { deadline: "2026-10-28T20:45:00Z", etaKind: "over", countdownOver: "" }, textContent: "+12m over" };
  const root = { querySelectorAll: () => [ hero ] };

  tick(root, deadline - 60 * 1000);
  assert.equal(hero.textContent, "01:00");
  assert.equal(hero.dataset.etaKind, "left", "painted over by the server, back to left once time is left");
});
