// [unit] build_status: the theme card's Dark / Light control is a toggle (a tap
// on the side already showing flips to the other), the status card pops only
// when a render first draws it, and Pick three new themes sends its line through
// the chat box's own submit. Run against stand-in elements.
import { test } from "node:test";
import assert from "node:assert/strict";

import { POP_CLASS, askAgent, cardAppeared, nextThemeMode, popStatusCard } from "../../app/javascript/build_status.js";

test("a tap on the other side shows it; a tap on the side showing flips it", () => {
  assert.equal(nextThemeMode("dark", "light"), "light");
  assert.equal(nextThemeMode("light", "dark"), "dark");
  assert.equal(nextThemeMode("dark", "dark"), "light", "the active side flips to the other");
  assert.equal(nextThemeMode("light", "light"), "dark");
  assert.equal(nextThemeMode(undefined, "dark"), "dark", "no mode yet: the tap's own side");
});

test("the card pops only when the heading turns into the card", () => {
  assert.equal(cardAppeared("false", "true"), true, "Start App: heading to card");
  assert.equal(cardAppeared(undefined, "true"), true, "the slot arrived with the card");
  assert.equal(cardAppeared("true", "true"), false, "a poll redrawing the card is no new card");
  assert.equal(cardAppeared("false", "false"), false);
  assert.equal(cardAppeared("true", "false"), false);
});

function classList() {
  const set = new Set();
  return { set, add: (c) => set.add(c), remove: (c) => set.delete(c), contains: (c) => set.has(c) };
}

test("popStatusCard adds the pop class to the card, and is a no-op without one", () => {
  const card = { classList: classList(), offsetWidth: 300 };
  const root = { querySelector: (s) => (s === "[data-build-status-card]" ? card : null) };
  assert.equal(popStatusCard(root), true);
  assert.ok(card.classList.contains(POP_CLASS));
  clearTimeout(card._buildPopTimer);
  assert.equal(popStatusCard({ querySelector: () => null }), false);
});

function composer({ busy = false } = {}) {
  const field = { value: "", events: [], dispatchEvent(e) { this.events.push(e.type); } };
  const form = {
    submitted: 0, dataset: {},
    getAttribute: (name) => (name === "aria-busy" && busy ? "true" : null),
    querySelector: (s) => (s === "textarea" ? field : null),
    requestSubmit() { this.submitted += 1; },
  };
  const root = { querySelector: (s) => (s === "form[data-cto-chat-form]" ? form : null) };
  return { root, form, field };
}

test("the ask fills the chat box and submits it the composer's way", () => {
  const { root, form, field } = composer();
  assert.equal(askAgent("Can you give me three new theme ideas?", root), true);
  assert.equal(field.value, "Can you give me three new theme ideas?");
  assert.deepEqual(field.events, ["input"], "the box hears the new text, as if typed");
  assert.equal(form.submitted, 1, "requestSubmit, so Turbo and the composer's own handlers run");
});

test("no ask while a send is posting, without a chat box, or without text", () => {
  const busy = composer({ busy: true });
  assert.equal(askAgent("Hi", busy.root), false);
  assert.equal(busy.form.submitted, 0, "one send at a time");
  assert.equal(askAgent("Hi", { querySelector: () => null }), false);
  const idle = composer();
  assert.equal(askAgent("", idle.root), false);
  assert.equal(idle.form.submitted, 0);
});
