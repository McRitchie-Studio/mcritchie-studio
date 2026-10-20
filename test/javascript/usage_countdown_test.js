// [unit] usage_countdown: the CTO chat meter's "Resets in 3d 4h" countdown (task
// cto-chat-quality-pass). countdownLine must match AgentUsage.countdown_line,
// which paints the first value; tick rewrites every countdown span on the page.
import { test } from "node:test";
import assert from "node:assert/strict";

import { countdownLine, tick } from "../../app/javascript/usage_countdown.js";

test("days and hours, then hours and minutes, then minutes, rounded up", () => {
  assert.equal(countdownLine(3 * 86400 + 4 * 3600), "Resets in 3d 4h");
  assert.equal(countdownLine(4 * 3600 + 12 * 60), "Resets in 4h 12m");
  assert.equal(countdownLine(11 * 60 + 1), "Resets in 12m");
  assert.equal(countdownLine(1), "Resets in 1m");
  assert.equal(countdownLine(86400), "Resets in 1d 0h");
  assert.equal(countdownLine(0), "Resetting now");
  assert.equal(countdownLine(-5), "Resetting now");
});

test("tick rewrites each countdown from its reset time", () => {
  const span = { dataset: { resetsAt: "1000000" }, textContent: "Resets in 9d 0h" };
  const bad = { dataset: { resetsAt: "nope" }, textContent: "keep" };
  const root = { querySelectorAll: (sel) => (sel === "[data-usage-countdown]" ? [ span, bad ] : []) };
  tick(root, (1000000 - 3600 * 5 - 60 * 3) * 1000);
  assert.equal(span.textContent, "Resets in 5h 3m");
  assert.equal(bad.textContent, "keep", "a span with no reset time is left alone");
});
