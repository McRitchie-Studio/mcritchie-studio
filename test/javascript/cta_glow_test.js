// [unit] cta_glow: the glow behind the theme card's Choose Theme follows the
// selected option, so picking another theme moves the glow to its colours, and
// it is spent while the pick is the theme already chosen. Run against stand-in
// elements: the rule reads data attributes and writes three style properties.
import { test } from "node:test";
import assert from "node:assert/strict";

import { themeGlowVars, syncThemeGlow } from "../../app/javascript/cta_glow.js";

function option(value, a, b, c, checked = false) {
  return { value, checked, dataset: { glowA: a, glowB: b, glowC: c } };
}

function card(options, chosenIndex) {
  const props = {};
  const glow = { dataset: {}, style: { setProperty: (name, value) => { props[name] = value; } } };
  const root = {
    dataset: chosenIndex === undefined ? {} : { chosenIndex },
    querySelector: (selector) => {
      if (selector === "[data-build-theme-glow]") return glow;
      if (selector === "input[name='index']:checked") return options.find((o) => o.checked) || null;
      return null;
    },
  };
  return { root, glow, props, options };
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
