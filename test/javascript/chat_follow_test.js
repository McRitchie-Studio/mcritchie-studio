// [unit] chat_follow: the chat thread follows new text for a reader within 20px
// of its end, and leaves a reader who scrolled further up where they are (task
// build-flow-polish; Alex McRitchie, 2026-10-19). Driven with a stand-in scroll box and
// stand-in observers: the rule reads scrollHeight, clientHeight and scrollTop
// and writes scrollTop.
import { test } from "node:test";
import assert from "node:assert/strict";

import { FOLLOW_PX, bind, distanceFromEnd, follow, following, isFollowing, stickIfFollowing } from "../../app/javascript/chat_follow.js";

// A thread 400px tall showing 300px of it, and the observers bind() makes.
function thread({ height = 400, box = 300, top = 100 } = {}) {
  const listeners = {};
  let scrolled = top;
  const log = {
    scrollHeight: height, clientHeight: box, children: [],
    // As a browser does, scrollTop never passes the end.
    get scrollTop() { return scrolled; },
    set scrollTop(to) { scrolled = Math.max(0, Math.min(to, this.scrollHeight - this.clientHeight)); },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    removeEventListener(type, fn) { listeners[type] = (listeners[type] || []).filter((f) => f !== fn); },
    // The reader scrolls: the browser moves scrollTop and fires scroll.
    scrollTo(to) { this.scrollTop = to; (listeners.scroll || []).forEach((fn) => fn()); },
    listeners,
  };
  const observers = { resize: [], mutation: [] };
  class Resize { constructor(fn) { this.fn = fn; this.targets = new Set(); this.live = true; observers.resize.push(this); }
    observe(el) { this.targets.add(el); } disconnect() { this.live = false; this.targets.clear(); } }
  class Mutation { constructor(fn) { this.fn = fn; this.live = true; observers.mutation.push(this); }
    observe() {} disconnect() { this.live = false; } }
  // Text typed in or a turn arriving: the thread grows, and the observer fires.
  const grow = (px) => { log.scrollHeight += px; observers.resize.filter((o) => o.live).forEach((o) => o.fn([])); };
  return { log, observers, grow, Resize, Mutation };
}

test("the end is within 20px", () => {
  assert.equal(FOLLOW_PX, 20);
  const { log } = thread({ top: 100 });
  assert.equal(distanceFromEnd(log), 0);
  log.scrollTop = 80;
  assert.equal(isFollowing(log), true, "20px up still follows");
  log.scrollTop = 79;
  assert.equal(isFollowing(log), false, "21px up is reading back");
});

test("[unit] a reader at the end stays pinned as an answer types in and as a new turn lands", () => {
  const t = thread();
  bind(t.log, { Resize: t.Resize, Mutation: t.Mutation });
  for (let i = 0; i < 10; i += 1) t.grow(7); // letter by letter
  assert.equal(distanceFromEnd(t.log), 0, "kept at the end while the words type");
  t.grow(180); // a new turn
  assert.equal(distanceFromEnd(t.log), 0, "and when a turn lands");
});

test("[unit] a reader within 20px of the end is still pinned when the text grows", () => {
  const t = thread();
  bind(t.log, { Resize: t.Resize, Mutation: t.Mutation });
  t.log.scrollTo(t.log.scrollTop - 15);
  assert.equal(following(), true);
  t.grow(60);
  assert.equal(distanceFromEnd(t.log), 0, "bumped to the end");
});

test("[unit] a reader scrolled up 200px is not moved by new text, and follows again once back at the end", () => {
  const t = thread({ height: 1000, box: 300, top: 700 });
  bind(t.log, { Resize: t.Resize, Mutation: t.Mutation });
  t.log.scrollTo(500);
  assert.equal(following(), false);
  t.grow(120);
  t.grow(40);
  assert.equal(t.log.scrollTop, 500, "left exactly where they were");
  stickIfFollowing(t.log);
  assert.equal(t.log.scrollTop, 500, "a stream render or a step of the head does not move them either");

  t.log.scrollTo(t.log.scrollHeight);
  assert.equal(following(), true, "scrolling back to the end follows again");
  t.grow(30);
  assert.equal(distanceFromEnd(t.log), 0);
});

test("[unit] the reader's own send brings them back to the end", () => {
  const t = thread({ height: 1000, box: 300, top: 700 });
  bind(t.log, { Resize: t.Resize, Mutation: t.Mutation });
  t.log.scrollTo(200);
  follow(t.log);
  assert.equal(distanceFromEnd(t.log), 0);
  assert.equal(following(), true);
});

test("[unit] one binding per thread: binding again adds nothing, and a new thread lets the old one go", () => {
  const a = thread();
  const first = bind(a.log, { Resize: a.Resize, Mutation: a.Mutation });
  assert.equal(bind(a.log, { Resize: a.Resize, Mutation: a.Mutation }), first, "a re-render binds nothing twice");
  assert.equal(a.log.listeners.scroll.length, 1, "one scroll listener, however many renders");
  assert.equal(a.observers.resize.length, 1);

  const b = thread();
  bind(b.log, { Resize: b.Resize, Mutation: b.Mutation });
  assert.equal(a.log.listeners.scroll.length, 0, "the replaced thread's listener is removed");
  assert.equal(a.observers.resize[0].live, false, "and its observers disconnected");
  assert.equal(a.observers.mutation[0].live, false);
  bind(null);
  assert.equal(b.log.listeners.scroll.length, 0, "a page with no thread holds nothing");
});
