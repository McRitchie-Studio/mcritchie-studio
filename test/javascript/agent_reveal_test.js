// [unit] agent_reveal: a new agent answer types itself in (task
// build-chat-reading-flow). The rendered HTML is kept (its text nodes fill in
// order; markup is never typed), an element shows once its first letter is due,
// the speed is natural and capped, reduced motion shows it at once, and an answer
// already on the page (history) is never typed. Driven with stand-in nodes.
import { test } from "node:test";
import assert from "node:assert/strict";

import { CHARS_PER_SECOND, MAX_MS, MIN_MS, answeredTurns, busy, finishRevealing, typeAnswer, lettersDue, newAnswers, paintReveal, prepareReveal, reveal, revealDuration }
  from "../../app/javascript/agent_reveal.js";

function text(data) { return { nodeType: 3, data }; }
function el(tag, ...children) {
  const attrs = new Map();
  return {
    nodeType: 1, tag, childNodes: children, isConnected: true,
    setAttribute: (name, value) => attrs.set(name, value),
    removeAttribute: (name) => attrs.delete(name),
    hasAttribute: (name) => attrs.has(name),
  };
}
function html(node) {
  if (node.nodeType === 3) return node.data;
  const inner = node.childNodes.map(html).join("");
  return node.tag ? `<${node.tag}${node.hasAttribute("data-agent-unrevealed") ? " hidden" : ""}>${inner}</${node.tag}>` : inner;
}
// <p>Hi <strong>there</strong>.</p>\n<ul><li>One</li><li>Two</li></ul>
function answer() {
  return el(null, el("p", text("Hi "), el("strong", text("there")), text(".")), text("\n"),
            el("ul", el("li", text("One")), el("li", text("Two"))));
}
function clock() {
  let t = 0;
  const queued = [];
  return { now: () => t, frame: (fn) => queued.push(fn), advance(ms) { t += ms; queued.splice(0).forEach((fn) => fn()); }, pending: () => queued.length };
}

test("the reveal keeps the answer's markup and fills its words in order", () => {
  const root = answer();
  const state = prepareReveal(root);
  assert.equal(state.total, "Hi there.OneTwo".length, "blank text between blocks is not counted");

  paintReveal(state, 0);
  assert.equal(html(root), "<p hidden><strong hidden></strong></p>\n<ul hidden><li hidden></li><li hidden></li></ul>");
  paintReveal(state, 5);
  assert.equal(html(root), "<p>Hi <strong>th</strong></p>\n<ul hidden><li hidden></li><li hidden></li></ul>",
               "the bold is bold from its first letter; nothing ahead of the cursor shows");
  paintReveal(state, 11);
  assert.equal(html(root), "<p>Hi <strong>there</strong>.</p>\n<ul><li>On</li><li hidden></li></ul>", "a bullet shows only with its words");
  paintReveal(state, state.total);
  assert.equal(html(root), "<p>Hi <strong>there</strong>.</p>\n<ul><li>One</li><li>Two</li></ul>");
});

test("natural speed, never a flash and never a long wait", () => {
  assert.equal(revealDuration(0), 0);
  assert.equal(revealDuration(12), MIN_MS, "a short answer still types, not flashes");
  assert.equal(revealDuration(CHARS_PER_SECOND), 1000);
  assert.equal(revealDuration(20000), MAX_MS, "a long answer is capped");
  assert.ok(MAX_MS <= 3000);
  // About 25 letters a 60ms beat at speed.
  const perBeat = (CHARS_PER_SECOND * 60) / 1000;
  assert.ok(perBeat >= 20 && perBeat <= 40, `${perBeat} letters a beat`);
  assert.equal(lettersDue(100, 0, 1000), 0);
  assert.equal(lettersDue(100, 500, 1000), 50);
  assert.equal(lettersDue(100, 1200, 1000), 100);
});

test("reveal() types by the clock and ends with the whole answer", () => {
  const root = answer();
  const c = clock();
  let paints = 0;
  let done = 0;
  const handle = reveal(root, { now: c.now, frame: c.frame, reduced: false, onPaint: () => { paints += 1; }, onDone: () => { done += 1; } });
  assert.equal(handle.duration, MIN_MS);
  assert.equal(html(root).includes("there"), false, "nothing shows before the first frame");
  c.advance(handle.duration / 2);
  assert.ok(html(root).includes("Hi"), "half way, the first words are down");
  assert.equal(html(root).includes("Two"), false);
  c.advance(handle.duration);
  assert.equal(html(root), "<p>Hi <strong>there</strong>.</p>\n<ul><li>One</li><li>Two</li></ul>");
  assert.equal(done, 1);
  assert.ok(paints >= 2);
  assert.equal(c.pending(), 0, "no frame left running");
});

test("reduced motion shows the answer at once, untouched", () => {
  const root = answer();
  let done = 0;
  const c = clock();
  reveal(root, { now: c.now, frame: c.frame, reduced: true, onDone: () => { done += 1; } });
  assert.equal(html(root), "<p>Hi <strong>there</strong>.</p>\n<ul><li>One</li><li>Two</li></ul>");
  assert.equal(done, 1);
  assert.equal(c.pending(), 0);
});

test("finish() shows it all at once; an answer taken off the page stops typing", () => {
  const root = answer();
  const c = clock();
  const handle = reveal(root, { now: c.now, frame: c.frame, reduced: false });
  handle.finish();
  assert.equal(html(root), "<p>Hi <strong>there</strong>.</p>\n<ul><li>One</li><li>Two</li></ul>");

  const gone = answer();
  const c2 = clock();
  let done = 0;
  reveal(gone, { now: c2.now, frame: c2.frame, reduced: false, onDone: () => { done += 1; } });
  gone.isConnected = false;
  c2.advance(10);
  assert.equal(c2.pending(), 0, "a replaced turn's reveal lets go");
  assert.equal(done, 1, "and says it is done, so the live region it held busy is freed");
});

test("[unit] the live region is busy while any answer types, and freed when the last one ends (task build-flow-polish)", () => {
  const attrs = new Map();
  const log = { setAttribute: (k, v) => attrs.set(k, v), removeAttribute: (k) => attrs.delete(k) };
  busy(log, +1);
  assert.equal(attrs.get("aria-busy"), "true");
  busy(log, +1);
  busy(log, -1);
  assert.equal(attrs.get("aria-busy"), "true", "a second answer still typing keeps it busy");
  busy(log, -1);
  assert.equal(attrs.has("aria-busy"), false, "the reader hears the finished answers once");
  busy(log, -1);
  assert.equal(attrs.has("aria-busy"), false, "never below zero");
  busy(null, +1);
});

test("history is never typed: only an answer the page has not seen is new", () => {
  const body = (id) => ({ closest: () => ({ id }) });
  const page = (...bodies) => ({ querySelectorAll: () => bodies });
  const seen = answeredTurns(page(body("cto-chat-turn-1"), body("cto-chat-turn-2")));
  assert.deepEqual([ ...seen ], [ "cto-chat-turn-1", "cto-chat-turn-2" ]);

  const fresh = body("cto-chat-turn-3");
  const after = page(body("cto-chat-turn-1"), body("cto-chat-turn-2"), fresh);
  assert.deepEqual(newAnswers(after, seen), [ fresh ], "the answer that arrived is the one typed");
  assert.deepEqual(newAnswers(after, seen), [], "a re-render of an answer already typed shows at once");
});

test("[unit] leaving mid-typing finishes the answer before Turbo caches the page: whole text, links live, region not busy (task build-flow-polish)", () => {
  const attrs = new Map();
  const log = { setAttribute: (k, v) => attrs.set(k, v), removeAttribute: (k) => attrs.delete(k) };
  const turn = el("div");
  const root = answer();
  root.closest = (selector) => (selector === "[data-cto-chat-scroll]" ? log : selector === "[data-build-turn]" ? turn : null);
  const c = clock();
  typeAnswer(root, { now: c.now, frame: c.frame, reduced: false });
  c.advance(100);
  assert.equal(root.inert, true, "mid-typing the words are inert");
  assert.equal(attrs.get("aria-busy"), "true");
  assert.equal(turn.hasAttribute("data-agent-revealing"), true);
  assert.notEqual(html(root), "<p>Hi <strong>there</strong>.</p>\n<ul><li>One</li><li>Two</li></ul>", "still typing");

  finishRevealing(); // turbo:before-cache
  assert.equal(html(root), "<p>Hi <strong>there</strong>.</p>\n<ul><li>One</li><li>Two</li></ul>", "the whole answer is in the snapshot");
  assert.equal(root.inert, false, "its links work after Back");
  assert.equal(attrs.has("aria-busy"), false);
  assert.equal(turn.hasAttribute("data-agent-revealing"), false);
  finishRevealing(); // a second cache finds nothing typing
});
