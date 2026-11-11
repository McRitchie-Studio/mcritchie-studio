// [unit] The Studio Sheets add-on's style rules (addons/studio-sheets/src/Style.js
// over the generated Brands.js): head section spans, the title alignment, the
// column letters, and the age colours' rules as plain data. One test reads the
// drawer (script/marketing_kit/office.py) so the two sets of age bands cannot drift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { loadAddon } from "./support/studio_sheets_addon.mjs";

const style = loadAddon({}, ["Brands.js", "Logic.js", "Style.js"]);
const plain = (value) => JSON.parse(JSON.stringify(value));
const OFFICE = fileURLToPath(new URL("../../script/marketing_kit/office.py", import.meta.url));

// --- Brands -------------------------------------------------------------------------

test("every brand has three head sections, a title, a headline and a font", () => {
  assert.deepEqual(Object.keys(style.STUDIO_BRANDS), ["CW", "MI", "MS", "TM"]);
  for (const [code, brand] of Object.entries(style.STUDIO_BRANDS)) {
    assert.equal(brand.sections.length, 3, code);
    for (const s of brand.sections) {
      assert.match(s.top, /^#[0-9A-F]{6}$/, code);
      assert.match(s.low, /^#[0-9A-F]{6}$/, code);
    }
    assert.match(brand.title, /^#[0-9A-F]{6}$/, code);
    assert.match(brand.headline, /^#[0-9A-F]{6}$/, code);
    assert.equal(brand.font, "Montserrat", code);
  }
  assert.equal(style.studioBrand("MI").name, "McRitchie Industries");
  assert.equal(style.studioBrand("XX"), null);
  assert.equal(style.studioBrand("constructor"), null, "only a brand's own key");
});

test("the kit's centre is Apps Script's middle; bottom stays bottom", () => {
  assert.equal(style.studioVerticalAlignment("center"), "middle");
  assert.equal(style.studioVerticalAlignment("bottom"), "bottom");
  assert.equal(style.studioVerticalAlignment(undefined), "middle");
});

// --- Section spans -----------------------------------------------------------------

test("labelled sections run from each label to the cell before the next", () => {
  // The drawer's layout: B item, C gutter, D-F section two, G-H section three.
  const top = ["", "Card", "", "Terms", "", "", "Rewards", ""];
  const low = ["", "Card", "", "Limit", "Used", "Last Used", "Archived", "Notes"];
  assert.deepEqual(plain(style.studioSectionSpans(top, low)), [
    { start: 2, end: 3, section: 0 },
    { start: 4, end: 6, section: 1 },
    { start: 7, end: 8, section: 2 }
  ]);
});

test("columns before the first label join the first section; a fourth label reuses colour one", () => {
  const top = ["", "", "", "One", "Two", "Three", "Four"];
  const low = ["", "a", "b", "c", "d", "e", "f"];
  assert.deepEqual(plain(style.studioSectionSpans(top, low)), [
    { start: 2, end: 4, section: 0 },
    { start: 5, end: 5, section: 1 },
    { start: 6, end: 6, section: 2 },
    { start: 7, end: 7, section: 0 }
  ]);
});

test("with no labels the headed columns split into three, the first ones widest", () => {
  const low = ["", "a", "b", "c", "d", "e", "f", "g"];
  assert.deepEqual(plain(style.studioSectionSpans([], low)), [
    { start: 2, end: 4, section: 0 },
    { start: 5, end: 6, section: 1 },
    { start: 7, end: 8, section: 2 }
  ]);
  assert.deepEqual(plain(style.studioSectionSpans([], ["", "a", "b"])), [
    { start: 2, end: 2, section: 0 },
    { start: 3, end: 3, section: 1 }
  ]);
});

test("a sheet with no head has no sections, and column A never counts", () => {
  assert.deepEqual(plain(style.studioSectionSpans([], [])), []);
  assert.deepEqual(plain(style.studioSectionSpans(["Margin"], ["Margin"])), []);
});

// --- Age colours ---------------------------------------------------------------------

test("column letters run past Z", () => {
  assert.deepEqual([1, 2, 26, 27, 52, 703].map(style.studioColumnLetter), ["A", "B", "Z", "AA", "AZ", "AAA"]);
});

test("the age rules cut the date column out of the row ranges, archived first", () => {
  // B item .. H; F is Last Used, G Archived.
  const rules = plain(style.studioAgeRules({
    ageColumn: 6, firstColumn: 2, lastColumn: 8, firstRow: 9, lastRow: 1000, archivedColumn: 7, addArchived: true
  }));
  const rows = [{ row: 9, column: 2, numRows: 992, numColumns: 4 }, { row: 9, column: 7, numRows: 992, numColumns: 2 }];
  const cell = [{ row: 9, column: 6, numRows: 992, numColumns: 1 }];

  assert.equal(rules.length, 9);
  // Archived greys the row and the date cell first.
  assert.deepEqual(rules[0], { ranges: rows, formula: '=$G9="Archived"', background: "#F3F5F8", fontColor: "#5A6675", bold: false, italic: true });
  assert.deepEqual(rules[1].ranges, cell);
  assert.equal(rules[1].formula, '=$G9="Archived"');
  // Four row bands, freshest first, never touching the date column.
  assert.deepEqual(rules.slice(2, 6).map((r) => [r.formula, r.background]), [
    ['=OR($F9="💳",$F9="🔄",AND(ISNUMBER($F9),$F9>=EDATE(TODAY(),-4)))', "#D9EAD3"],
    ["=AND(ISNUMBER($F9),$F9>=EDATE(TODAY(),-10))", "#FFFFFF"],
    ["=AND(ISNUMBER($F9),$F9>=EDATE(TODAY(),-16))", "#FFF2CC"],
    ["=AND(ISNUMBER($F9),$F9<EDATE(TODAY(),-16))", "#F4CCCC"]
  ]);
  for (const r of rules.slice(2, 6)) assert.deepEqual(r.ranges, rows);
  // The date cell: deep red, then amber, then green.
  assert.deepEqual(rules.slice(6).map((r) => [r.formula, r.background, r.fontColor, r.bold]), [
    ["=AND(ISNUMBER($F9),$F9<EDATE(TODAY(),-16))", "#CC0000", "#FFFFFF", true],
    ["=AND(ISNUMBER($F9),$F9<EDATE(TODAY(),-10))", "#F1C232", null, true],
    ['=OR($F9="💳",$F9="🔄",AND(ISNUMBER($F9),$F9>=EDATE(TODAY(),-4)))', "#D9EAD3", null, false]
  ]);
  for (const r of rules.slice(6)) assert.deepEqual(r.ranges, cell);
});

test("no Archived rule is added when one exists or there is no Archived column", () => {
  const base = { ageColumn: 6, firstColumn: 2, lastColumn: 8, firstRow: 9, lastRow: 20 };
  assert.equal(style.studioAgeRules({ ...base, archivedColumn: 7, addArchived: false }).length, 7);
  assert.equal(style.studioAgeRules({ ...base, archivedColumn: 0, addArchived: true }).length, 7);
});

test("a date column at the table's edge leaves one row range", () => {
  const last = plain(style.studioAgeRules({ ageColumn: 8, firstColumn: 2, lastColumn: 8, firstRow: 9, lastRow: 9, archivedColumn: 0 }));
  assert.deepEqual(last[0].ranges, [{ row: 9, column: 2, numRows: 1, numColumns: 6 }]);
  const only = plain(style.studioAgeRules({ ageColumn: 2, firstColumn: 2, lastColumn: 2, firstRow: 9, lastRow: 9, archivedColumn: 0 }));
  assert.equal(only.length, 3, "a one-column table has the cell rules only");
});

test("existing rules sort into Archived (first), the age rules (dropped) and the rest", () => {
  const formulas = ['=$G9="Archived"', "=AND(ISNUMBER($F9),$F9<EDATE(TODAY(),-16))", null, "=$B9>100", '=$G$9="Archived"'];
  assert.deepEqual(plain(style.studioSortExistingRules(formulas)), { archived: [0, 4], others: [2, 3] });
});

test("the age bands are the drawer's, colour for colour", () => {
  const office = readFileSync(OFFICE, "utf8");
  const block = office.slice(office.indexOf("# age_bands:"), office.indexOf("ws.auto_filter"));
  const bands = style.STUDIO_AGE_BANDS;
  for (const hex of [...bands.rows, bands.cell.old.background, bands.cell.old.fontColor, bands.cell.warn.background, bands.cell.fresh.background]) {
    assert.ok(block.includes(`"${hex.slice(1)}"`), `office.py's age_bands uses ${hex}`);
  }
  assert.match(block, /good, "D9EAD3"\), \(dated\(">=", m1\), "FFFFFF"\), \(dated\(">=", m2\), "FFF2CC"\), \(dated\("<", m2\), "F4CCCC"\)/,
    "row bands in the drawer's order");
  assert.deepEqual(plain(bands.months), [4, 10, 16]);
});
