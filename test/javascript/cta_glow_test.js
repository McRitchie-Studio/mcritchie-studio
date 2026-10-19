// [unit] cta_glow: the glow behind the theme card's Choose Theme follows the
// selected option, so picking another theme moves the glow to its colours, and
// it is spent while the pick is the theme already chosen. Run against stand-in
// elements: the rule reads data attributes and writes three style properties.
import { test } from "node:test";
import assert from "node:assert/strict";

import { glowSquash, releaseGlows, syncThemeGlow, themeGlowVars, watchGlows, watchedCount } from "../../app/javascript/cta_glow.js";

function option(value, a, b, c, checked = false) {
  return { value, checked, dataset: { glowA: a, glowB: b, glowC: c } };
}

function card(options, chosenIndex) {
  const props = {};
  const submit = { disabled: false };
  const glow = { dataset: {}, style: { setProperty: (name, value) => { props[name] = value; } },
                 querySelector: (selector) => (selector === "button[type='submit']" ? submit : null) };
  const root = {
    dataset: chosenIndex === undefined ? {} : { chosenIndex },
    querySelector: (selector) => {
      if (selector === "[data-build-theme-glow]") return glow;
      if (selector === "input[name='index']:checked") return options.find((o) => o.checked) || null;
      return null;
    },
  };
  return { root, glow, props, options, submit };
}

const PITCH = ["#15803d", "#f59e0b", "#4ade80"];
const FIELD = ["#1d4ed8", "#fbbf24", "#60a5fa"];

test("an option's colours are its glow variables; a malformed one gives none", () => {
  assert.deepEqual(themeGlowVars(option("0", ...PITCH)), { "--glow-a": "#15803d", "--glow-b": "#f59e0b", "--glow-c": "#4ade80" });
  assert.equal(themeGlowVars(option("0", "red", "#f59e0b", "#4ade80")), null);
  assert.equal(themeGlowVars(option("0", "#15803d;x", "#f59e0b", "#4ade80")), null, "only a hex reaches the style");
});

test("picking another theme moves the glow to that theme's colours", () => {
  const { root, props, options } = card([option("0", ...PITCH, true), option("1", ...FIELD)]);
  syncThemeGlow(root);
  assert.equal(props["--glow-a"], "#15803d");

  options[0].checked = false;
  options[1].checked = true;
  syncThemeGlow(root);
  assert.deepEqual(props, { "--glow-a": "#1d4ed8", "--glow-b": "#fbbf24", "--glow-c": "#60a5fa" });
});

test("the glow is spent while the pick is the theme already chosen, and returns for another", () => {
  const { root, glow, options } = card([option("0", ...PITCH, true), option("1", ...FIELD)], "0");
  syncThemeGlow(root);
  assert.equal(glow.dataset.glow, "off");
  options[0].checked = false;
  options[1].checked = true;
  syncThemeGlow(root);
  assert.equal(glow.dataset.glow, undefined);
});

test("[unit] Choose Theme is disabled while the pick is the theme already chosen, and enabled for another (task build-flow-polish)", () => {
  const { root, options, submit } = card([option("0", ...PITCH, true), option("1", ...FIELD)], "0");
  syncThemeGlow(root);
  assert.equal(submit.disabled, true, "a re-tap on the chosen theme cannot post");
  options[0].checked = false;
  options[1].checked = true;
  syncThemeGlow(root);
  assert.equal(submit.disabled, false, "another theme can be chosen");
  options[1].checked = false;
  options[0].checked = true;
  syncThemeGlow(root);
  assert.equal(submit.disabled, true, "back on the chosen one, disabled again");
});

test("[unit] a card with no theme chosen yet keeps Choose Theme enabled", () => {
  const { root, submit } = card([option("0", ...PITCH, true)]);
  syncThemeGlow(root);
  assert.equal(submit.disabled, false);
});

test("[unit] the glow's circle is squashed to the CTA's shape", () => {
  assert.equal(glowSquash(100, 100), 1, "a round CTA keeps a circle");
  assert.equal(glowSquash(384, 40), 56 / 432, "a wide button: its glow box's height over its width");
  assert.equal(glowSquash(0, 40), 1, "an unmeasured CTA falls back to a circle");
  assert.ok(glowSquash(40, 384) <= 1, "never stretched taller than a circle");
});

test("[unit] watched glows are let go: removed ones on the next watch, all of them before Turbo caches the page", () => {
  const observed = new Set();
  globalThis.IntersectionObserver = class { observe(el) { observed.add(el); } unobserve(el) { observed.delete(el); } disconnect() { observed.clear(); } };
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  const glow = () => ({ isConnected: true, dataset: {}, style: { setProperty() {} } });
  const page = [glow(), glow()];
  const root = { querySelectorAll: () => page.filter((el) => !el.dataset.glowWatched) };
  try {
    watchGlows(root);
    assert.equal(watchedCount(), 2);
    watchGlows(root);
    assert.equal(watchedCount(), 2, "watching again adds nothing twice");

    page[0].isConnected = false; // a stream render took it off the page
    watchGlows(root);
    assert.equal(watchedCount(), 1, "the removed glow is no longer held");
    assert.equal(observed.has(page[0]), false);

    releaseGlows({ querySelectorAll: () => page.filter((el) => el.dataset.glowWatched) });
    assert.equal(watchedCount(), 0, "before-cache lets go of everything");
    assert.equal(page[1].dataset.glowWatched, undefined, "the cached copy is watched afresh on restore");
  } finally {
    delete globalThis.IntersectionObserver;
    delete globalThis.ResizeObserver;
  }
});
