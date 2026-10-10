// [unit] scroll_tab_stop: a sideways-scrolling region is a tab stop only while its
// content is wider than it is. Run against stand-in elements: the rule reads two
// widths and writes one attribute.
import { test } from "node:test";
import assert from "node:assert/strict";

import { scrolls, syncTabStop } from "../../app/javascript/scroll_tab_stop.js";

function region(scrollWidth, clientWidth, tabindex = "0") {
  const attributes = tabindex === null ? {} : { tabindex };
  return {
    scrollWidth, clientWidth, attributes,
    setAttribute(name, value) { attributes[name] = value; },
    removeAttribute(name) { delete attributes[name]; },
  };
}

test("a region scrolls when its content is wider, not when it is equal or narrower", () => {
  assert.equal(scrolls(region(874, 243)), true);
  assert.equal(scrolls(region(1028, 1028)), false);
  assert.equal(scrolls(region(900, 1028)), false);
});

test("a region whose content fits loses the tabindex it was served with", () => {
  const fits = region(1028, 1028);
  syncTabStop(fits);
  assert.deepEqual(fits.attributes, {});
});

test("a region whose content overflows keeps its tabindex, and gets it back after losing it", () => {
  const wide = region(874, 243);
  syncTabStop(wide);
  assert.deepEqual(wide.attributes, { tabindex: "0" });

  const narrowed = region(874, 243, null);
  syncTabStop(narrowed);
  assert.deepEqual(narrowed.attributes, { tabindex: "0" });
});
