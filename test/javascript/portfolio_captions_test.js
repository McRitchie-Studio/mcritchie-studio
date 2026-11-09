// [unit] portfolio_captions: the /websites caption follows the engine carousel's open
// slide (data-current). Run against stand-in elements.
import { test } from "node:test";
import assert from "node:assert/strict";

import { captionFor, sync } from "../../app/javascript/portfolio_captions.js";

function caption(url, current = false) {
  const attributes = new Map(current ? [["data-current", ""]] : [["aria-hidden", "true"]]);
  return {
    dataset: { portfolioUrl: url },
    attributes,
    toggleAttribute(name, on) { if (on) attributes.set(name, ""); else attributes.delete(name); },
    setAttribute(name, value) { attributes.set(name, value); },
    removeAttribute(name) { attributes.delete(name); },
  };
}

function stage(openHref, captions) {
  const card = openHref && { getAttribute: (name) => (name === "href" ? openHref : null) };
  return {
    querySelector: (selector) => (selector.includes("[data-current]") ? card : null),
    querySelectorAll: () => captions,
  };
}

test("the caption for a card is the one with the card's address", () => {
  const turf = caption("https://turfmonster.media");
  const welding = caption("https://commercialwelding.llc");
  assert.equal(captionFor([turf, welding], "https://commercialwelding.llc"), welding);
  assert.equal(captionFor([turf, welding], "https://nowhere.example"), null);
});

test("a move marks the open app's caption current and hides the rest from assistive tech", () => {
  const turf = caption("https://turfmonster.media", true);
  const welding = caption("https://commercialwelding.llc");
  sync(stage("https://commercialwelding.llc", [turf, welding]));

  assert.equal(welding.attributes.has("data-current"), true);
  assert.equal(welding.attributes.has("aria-hidden"), false);
  assert.equal(turf.attributes.has("data-current"), false);
  assert.equal(turf.attributes.get("aria-hidden"), "true");
});

test("no open card (a seam copy, or before the controller) leaves the caption as it was", () => {
  const turf = caption("https://turfmonster.media", true);
  const welding = caption("https://commercialwelding.llc");
  sync(stage(null, [turf, welding]));
  sync(stage("https://unknown.example", [turf, welding]));

  assert.equal(turf.attributes.has("data-current"), true);
  assert.equal(welding.attributes.has("data-current"), false);
});
