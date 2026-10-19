// [unit] agent_shell: the agent shell's size step (tasks build-launch-chat-growth,
// build-chat-reading-flow). The head compacts as the THREAD'S HEIGHT grows, not as
// messages are sent: past mediumShare of the shell's room, medium; past
// compactShare, compact; one step on whenever the thread has to scroll at the step
// it is on. Never back on a page; a load measures afresh from full. Driven with a
// stand-in shell and stand-in measurements.
import { test } from "node:test";
import assert from "node:assert/strict";

import { sizeFor, sizeFresh, sizeShell, thresholds, turnCount } from "../../app/javascript/agent_shell.js";

const SHARES = { mediumShare: 0.3, compactShare: 0.55 };

function shell(size = "full") {
  return { dataset: { shellSize: size, shellMediumShare: "0.3", shellCompactShare: "0.55" } };
}

test("a short thread keeps the full head however many messages were sent", () => {
  assert.equal(sizeFor("full", { turns: 4, content: 150, room: 700 }, SHARES), "full", "four one-line turns still fit beside the hero");
  assert.equal(sizeFor("full", { turns: 0, content: 900, room: 700, overflowing: true }, SHARES), "full", "an empty thread never compacts");
});

test("past the medium share the head shrinks; past the compact share it is one line", () => {
  assert.equal(sizeFor("full", { turns: 1, content: 0.29 * 700, room: 700 }, SHARES), "full");
  assert.equal(sizeFor("full", { turns: 1, content: 0.31 * 700, room: 700 }, SHARES), "medium");
  assert.equal(sizeFor("full", { turns: 2, content: 0.56 * 700, room: 700 }, SHARES), "compact");
  assert.equal(sizeFor("medium", { turns: 2, content: 0.56 * 700, room: 700 }, SHARES), "compact");
});

test("a thread that no longer fits beside the head steps it down one, under the shares", () => {
  assert.equal(sizeFor("full", { turns: 1, content: 100, room: 700, overflowing: true }, SHARES), "medium");
  assert.equal(sizeFor("medium", { turns: 1, content: 100, room: 700, overflowing: true }, SHARES), "compact");
  assert.equal(sizeFor("compact", { turns: 1, content: 100, room: 700, overflowing: true }, SHARES), "compact");
});

test("the step moves forward only: a compact head stays compact when its room un-scrolls the thread", () => {
  assert.equal(sizeFor("compact", { turns: 1, content: 10, room: 700 }, SHARES), "compact");
  assert.equal(sizeFor("medium", { turns: 1, content: 10, room: 700 }, SHARES), "medium");
  const page = shell("compact");
  assert.equal(sizeShell(page, () => ({ turns: 1, content: 10, room: 700, overflowing: false })), "compact");
});

test("no room measured yet (a hidden page) leaves the step alone", () => {
  assert.equal(sizeFor("full", { turns: 3, content: 900, room: 0 }, SHARES), "full");
});

test("a load measures afresh from full and stops at the step its thread asks for", () => {
  // A long thread: compact even though the server guessed full.
  const long = shell("full");
  assert.equal(sizeFresh(long, () => ({ turns: 5, content: 2000, room: 700, overflowing: true })), "compact");

  // A short thread the server guessed compact opens full: a reload is a new page.
  const short = shell("compact");
  assert.equal(sizeFresh(short, () => ({ turns: 2, content: 120, room: 700, overflowing: false })), "full");

  // Each step is measured after the last one's layout: medium's room fits it.
  const page = shell("full");
  const reads = [];
  const read = (s) => {
    reads.push(s.dataset.shellSize);
    return { turns: 2, content: 260, room: 700, overflowing: s.dataset.shellSize === "full" };
  };
  assert.equal(sizeFresh(page, read), "medium");
  assert.deepEqual(reads, ["full", "medium"], "at most one read per step, and it stops once settled");
});

test("the thresholds ride the shell; the empty-state line is not a turn", () => {
  assert.deepEqual(thresholds(shell()), SHARES);
  assert.deepEqual(thresholds({ dataset: {} }), SHARES, "the defaults match AgentShellHelper");
  const log = { children: [ { dataset: { test: "build-chat-empty" } }, { dataset: { test: "build-turn" } } ] };
  assert.equal(turnCount(log), 1);
  assert.equal(turnCount(null), 0);
});

test("a page with no shell is left alone", () => {
  assert.equal(sizeShell(null), null);
  assert.equal(sizeFresh(null), null);
});
