// [unit] build_domain: on the /build domain card the name field is the source
// of truth. The chip whose name the field holds exactly glows; an edit that
// matches no chip fades it; typing the name back, or another chip's name,
// lights that chip; Use Domain glows whenever the name is valid and not taken.
// Run against stand-in elements: the rule reads a value and data attributes
// and writes aria-pressed and data-build-glow.
import { test } from "node:test";
import assert from "node:assert/strict";

import { domainName, matchingChip, validDomain, syncDomainGlow, pickDomainChip } from "../../app/javascript/build_domain.js";

function element(dataset = {}, extra = {}) {
  const attributes = {};
  return { dataset: { ...dataset }, attributes, disabled: false, focused: false,
           setAttribute(name, value) { attributes[name] = value; }, focus() { this.focused = true; }, ...extra };
}

function card(value, names = [ "poke-offense", "pokemon-lineup", "lineup-drafter" ]) {
  const input = element({}, { value });
  const chips = names.map((name) => element({ buildDomainName: name }));
  const submit = element();
  const root = {
    querySelector: (selector) => ({ "[data-build-address-input]": input, "[data-build-address-submit]": submit })[selector] ?? null,
    querySelectorAll: (selector) => (selector === "[data-build-domain-name]" ? chips : []),
  };
  return { root, input, chips, submit };
}

const glowing = (chips) => chips.filter((chip) => chip.attributes["aria-pressed"] === "true").map((chip) => chip.dataset.buildDomainName);

test("a trailing hyphen still being typed is not part of the name", () => {
  assert.equal(domainName("poke-offense-"), "poke-offense");
  assert.equal(domainName(undefined), "");
});

test("only an exact match is a chip", () => {
  assert.equal(matchingChip("poke-offense", [ "poke-offense", "x-y-z" ]), "poke-offense");
  assert.equal(matchingChip("poke-offens", [ "poke-offense" ]), null);
  assert.equal(matchingChip("poke-offense-x", [ "poke-offense" ]), null);
});

test("a valid name is the server's format: 3 to 30, letters, numbers and inner hyphens", () => {
  assert.equal(validDomain("poke-offense"), true);
  assert.equal(validDomain("ab"), false);
  assert.equal(validDomain("-poke"), false);
  assert.equal(validDomain("a".repeat(31)), false);
});

test("the preselected chip glows, an edit fades it, and typing it back brings the glow back", () => {
  const { root, input, chips, submit } = card("poke-offense");
  assert.equal(syncDomainGlow(root), "poke-offense");
  assert.deepEqual(glowing(chips), [ "poke-offense" ]);
  assert.equal(submit.dataset.buildGlow, "true");

  input.value = "poke-offensive";
  assert.equal(syncDomainGlow(root), null);
  assert.deepEqual(glowing(chips), [], "an edit that matches no chip fades every chip");
  assert.equal(submit.dataset.buildGlow, "true", "Use Domain still glows: the name is valid");

  input.value = "poke-offense";
  syncDomainGlow(root);
  assert.deepEqual(glowing(chips), [ "poke-offense" ], "typed back to the original, it glows again");
});

test("typing another suggestion's name moves the glow to that chip", () => {
  const { root, input, chips } = card("poke-offense");
  input.value = "pokemon-lineup";
  syncDomainGlow(root);
  assert.deepEqual(glowing(chips), [ "pokemon-lineup" ]);
});

test("Use Domain stops glowing on an invalid or taken name", () => {
  const { root, input, submit } = card("p");
  syncDomainGlow(root);
  assert.equal(submit.dataset.buildGlow, "false");
  input.value = "pokemon-lineup";
  syncDomainGlow(root, { taken: true });
  assert.equal(submit.dataset.buildGlow, "false");
});

test("a chip tap fills the field and glows, without focusing the field; a disabled chip does nothing", () => {
  const { root, input, chips } = card("poke-offense");
  assert.equal(pickDomainChip(root, chips[2]), "lineup-drafter");
  assert.equal(input.value, "lineup-drafter");
  assert.deepEqual(glowing(chips), [ "lineup-drafter" ]);
  assert.equal(input.focused, false, "no keyboard pops up on a phone");

  chips[1].disabled = true;
  assert.equal(pickDomainChip(root, chips[1]), null);
  assert.equal(input.value, "lineup-drafter");
});
