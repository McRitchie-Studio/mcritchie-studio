// [unit] dreams_filter: the /dreams status filter shows a card when its status
// matches and a stage group when any of its cards does, recounts each "N dreams"
// label, and marks the active control aria-current. Run against stand-in
// elements: the rule reads attributes and writes `hidden`, text and two classes.
import { test } from "node:test";
import assert from "node:assert/strict";

import { matches, countFor, dreamCountLabel, applyFilter } from "../../app/javascript/dreams_filter.js";

function element(attributes) {
  const classes = new Set();
  return {
    attributes: { ...attributes }, hidden: false,
    getAttribute(name) { return this.attributes[name] ?? null; },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    removeAttribute(name) { delete this.attributes[name]; },
    textContent: "",
    classList: { toggle(name, on) { on ? classes.add(name) : classes.delete(name); }, has: (name) => classes.has(name) },
  };
}

function page() {
  const cards = [ element({ "data-status": "approved" }), element({ "data-status": "proposed" }) ];
  const groups = [ element({ "data-statuses": "approved" }), element({ "data-statuses": "approved proposed" }) ];
  const buttons = [ "all", "approved", "proposed" ].map((f) => element({ "data-dreams-filter-button": f }));
  const counts = [ element({ "data-dream-count": "approved proposed approved" }), element({ "data-dream-count": "" }) ];
  const root = element({ "data-dreams-filter": "all" });
  root.querySelectorAll = (selector) => ({
    "[data-status]": cards, "[data-statuses]": groups, "[data-dreams-filter-button]": buttons,
    "[data-dream-count]": counts,
  })[selector];
  return { root, cards, groups, buttons, counts };
}

test("all matches every status; a named filter matches only its own", () => {
  assert.equal(matches("approved", "all"), true);
  assert.equal(matches("approved proposed", "proposed"), true);
  assert.equal(matches("approved", "proposed"), false);
  assert.equal(matches("", "approved"), false);
});

test("the proposed filter hides approved cards and groups with no proposed dream", () => {
  const { root, cards, groups, buttons } = page();
  applyFilter(root, "proposed");

  assert.deepEqual(cards.map((c) => c.hidden), [ true, false ]);
  assert.deepEqual(groups.map((g) => g.hidden), [ true, false ]);
  assert.equal(root.getAttribute("data-dreams-filter"), "proposed");
  assert.deepEqual(buttons.map((b) => b.getAttribute("aria-current")), [ null, null, "page" ]);
  assert.equal(buttons[2].classList.has("bg-primary"), true);
  assert.equal(buttons[0].classList.has("bg-primary"), false);
});

test("going back to all shows everything again", () => {
  const { root, cards, groups } = page();
  applyFilter(root, "proposed");
  applyFilter(root, "all");

  assert.equal([ ...cards, ...groups ].some((e) => e.hidden), false);
});

test("countFor counts every token under all and only its own status otherwise", () => {
  assert.equal(countFor("approved proposed approved", "all"), 3);
  assert.equal(countFor("approved proposed approved", "approved"), 2);
  assert.equal(countFor("approved proposed approved", "proposed"), 1);
  assert.equal(countFor("", "all"), 0);
  assert.equal(countFor(null, "proposed"), 0);
  assert.equal(dreamCountLabel(1), "1 dream");
  assert.equal(dreamCountLabel(0), "0 dreams");
});

test("the dream counts follow the filter and aria-current moves with it", () => {
  const { root, counts, buttons } = page();
  applyFilter(root, "approved");
  assert.deepEqual(counts.map((c) => c.textContent), [ "2 dreams", "0 dreams" ]);
  assert.deepEqual(buttons.map((b) => b.getAttribute("aria-current")), [ null, "page", null ]);

  applyFilter(root, "proposed");
  assert.deepEqual(counts.map((c) => c.textContent), [ "1 dream", "0 dreams" ]);

  applyFilter(root, "all");
  assert.deepEqual(counts.map((c) => c.textContent), [ "3 dreams", "0 dreams" ]);
  assert.deepEqual(buttons.map((b) => b.getAttribute("aria-current")), [ "page", null, null ]);
});
