// [unit] logo_editor: the logo gallery's edit panel (task logo-part-editor). The contrast rule that warns about a
// picked colour under 3:1 against the page, and which of the form's fields stay out of the URL.
import { test } from "node:test";
import assert from "node:assert/strict";

import { hexToRgb, luminance, contrastRatio, contrastWarning, blankFields, MIN_CONTRAST } from "../../app/javascript/logo_editor.js";

test("a hex reads as rgb with or without its #, and anything else is null", () => {
  assert.deepEqual(hexToRgb("#635BB2"), [99, 91, 178]);
  assert.deepEqual(hexToRgb("eeecff"), [238, 236, 255]);
  assert.equal(hexToRgb("#FFF"), null);
  assert.equal(hexToRgb("red"), null);
});

test("luminance and contrast follow WCAG 2: black on white is 21, a colour on itself is 1", () => {
  assert.equal(luminance([0, 0, 0]), 0);
  assert.equal(luminance([255, 255, 255]), 1);
  assert.equal(contrastRatio([0, 0, 0], [255, 255, 255]), 21);
  assert.equal(contrastRatio([255, 255, 255], [0, 0, 0]), 21, "order does not matter");
  assert.equal(contrastRatio([99, 91, 178], [99, 91, 178]), 1);
});

test("the brand colours Alex McRitchie picks measure as the gallery warns about them", () => {
  const white = [255, 255, 255];
  assert.ok(contrastRatio(hexToRgb("#635BB2"), white) > MIN_CONTRAST, "Deep Violet reads on the light page");
  assert.ok(contrastRatio(hexToRgb("#EEECFF"), white) < MIN_CONTRAST, "Violet Mist all but vanishes on it");
});

test("a warning is written only under 3:1, with the colour's name and its ratio", () => {
  assert.equal(contrastWarning("Deep Violet", 6.2), "");
  assert.equal(contrastWarning("Deep Violet", 3), "");
  assert.equal(
    contrastWarning("Violet Mist", 1.16),
    "Violet Mist measures 1.1:1 against this page's background, under 3:1: it may be hard to see here."
  );
  assert.match(contrastWarning("Ember Orange", 2.97), /measures 2\.9:1/, "just under 3 never reads 3.0");
});

test("blank fields (as styled, a shown tagline) stay out of the URL; picked and hidden fields do not", () => {
  const fields = [
    { name: "first_colour", value: "", disabled: false },
    { name: "first_colour", value: "635BB2", disabled: false },
    { name: "tagline_visible", value: "", disabled: false },
    { name: "first_weight", value: "", disabled: true },
    { name: "", value: "", disabled: false },
    { name: "type", value: "stacked", disabled: false },
  ];
  assert.deepEqual(blankFields(fields).map((f) => f.name), ["first_colour", "tagline_visible"]);
});
