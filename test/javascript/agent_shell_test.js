// [unit] agent_shell: the agent shell's size step (task build-launch-chat-growth).
// The head compacts as turns arrive (full, medium, compact, at the thresholds the
// shell carries from AgentShellHelper), at once when the thread has to scroll,
// and never springs back open on the same page. Driven with a stand-in shell.
import { test } from "node:test";
import assert from "node:assert/strict";

import { sizeFor, sizeShell } from "../../app/javascript/agent_shell.js";

function shell({ turns = 0, size = "full", scrolling = false, empty = true } = {}) {
  const children = Array.from({ length: turns }, () => ({ dataset: { test: "build-turn" } }));
  if (empty) children.unshift({ dataset: { test: "build-chat-empty" } });
  const log = { children, scrollHeight: scrolling ? 900 : 300, clientHeight: 300 };
  return { dataset: { shellSize: size, shellMediumAt: "1", shellCompactAt: "3" }, querySelector: () => log, log };
}

test("no turns is full; the first turn is medium; the third is compact; the empty line is not a turn", () => {
  assert.equal(sizeFor(shell({ turns: 0 })), "full");
  assert.equal(sizeFor(shell({ turns: 1 })), "medium");
  assert.equal(sizeFor(shell({ turns: 2 })), "medium");
  assert.equal(sizeFor(shell({ turns: 3 })), "compact");
});

test("a thread that has to scroll compacts the head at once", () => {
  assert.equal(sizeFor(shell({ turns: 1, scrolling: true })), "compact");
  assert.equal(sizeFor(shell({ turns: 0, scrolling: true })), "full", "an empty thread never compacts");
});

test("the step moves forward only: a compact head stays compact when its room un-scrolls the thread", () => {
  const page = shell({ turns: 1, scrolling: true });
  assert.equal(sizeShell(page), "compact");
  page.log.scrollHeight = 200;
  assert.equal(sizeShell(page), "compact");
  assert.equal(sizeShell(shell({ turns: 1, size: "medium" })), "medium");
  assert.equal(sizeShell(shell({ turns: 2, size: "full" })), "medium");
});

test("a page with no shell is left alone", () => {
  assert.equal(sizeShell(null), null);
});
