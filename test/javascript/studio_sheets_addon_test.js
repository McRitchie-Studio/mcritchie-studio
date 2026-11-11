// [integration] The Studio Sheets add-on's Apps Script layer (addons/studio-sheets/
// src/Studio.js) run against an in-memory SpreadsheetApp, ScriptApp and Utilities:
// the menu actions, the installable tick-box trigger, Apply brand style, the age
// colours, and the manifest and menu wiring a clasp push depends on.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { ADDON_DIR, loadAddon } from "./support/studio_sheets_addon.mjs";

// --- An in-memory sheet ----------------------------------------------------------

class FakeRange {
  constructor(sheet, row, column, numRows = 1, numColumns = 1) {
    Object.assign(this, { sheet, row, column, numRows, numColumns });
  }
  getRow() { return this.row; }
  getColumn() { return this.column; }
  getNumRows() { return this.numRows; }
  getNumColumns() { return this.numColumns; }
  getLastRow() { return this.row + this.numRows - 1; }
  getSheet() { return this.sheet; }
  getValues() {
    const out = [];
    for (let r = 0; r < this.numRows; r++) {
      const line = [];
      for (let c = 0; c < this.numColumns; c++) line.push(this.sheet.get(this.row + r, this.column + c));
      out.push(line);
    }
    return out;
  }
  setValues(values) {
    assert.equal(values.length, this.numRows, "setValues row count");
    values.forEach((line, r) => {
      assert.equal(line.length, this.numColumns, "setValues column count");
      line.forEach((value, c) => this.sheet.set(this.row + r, this.column + c, value));
    });
    this.sheet.writes += 1;
    return this;
  }
  setValue(value) {
    for (let r = 0; r < this.numRows; r++) {
      for (let c = 0; c < this.numColumns; c++) this.sheet.set(this.row + r, this.column + c, value);
    }
    this.sheet.writes += 1;
    return this;
  }
  setNumberFormat(format) {
    for (let r = 0; r < this.numRows; r++) {
      for (let c = 0; c < this.numColumns; c++) this.sheet.formats.set(`${this.row + r},${this.column + c}`, format);
    }
    return this;
  }
  // Cell formats. There is no merge(): a call to it would throw.
  style(key, value) {
    for (let r = 0; r < this.numRows; r++) {
      for (let c = 0; c < this.numColumns; c++) {
        const at = `${this.row + r},${this.column + c}`;
        this.sheet.styles.set(at, { ...this.sheet.styles.get(at), [key]: value });
      }
    }
    this.sheet.styleCalls += 1;
    return this;
  }
  setFontFamily(v) { return this.style("font", v); }
  setFontColor(v) { return this.style("color", v); }
  setFontSize(v) { return this.style("size", v); }
  setFontWeight(v) { return this.style("weight", v); }
  setVerticalAlignment(v) { return this.style("valign", v); }
  setBackground(v) { return this.style("background", v); }
  a1() { return `${this.row},${this.column},${this.numRows},${this.numColumns}`; }
}

class FakeSheet {
  // `rows` maps a row number to its cells from column A.
  constructor(rows = {}) {
    this.cells = new Map();
    this.formats = new Map();
    this.writes = 0;
    this.styles = new Map();
    this.styleCalls = 0;
    this.rules = [];
    this.frozen = { rows: 0, columns: 0 };
    this.gridlinesHidden = false;
    this.maxRows = 1000;
    this.maxColumns = 26;
    this.selection = [];
    for (const [row, line] of Object.entries(rows)) {
      line.forEach((value, i) => this.set(Number(row), i + 1, value));
    }
  }
  get(row, column) { return this.cells.has(`${row},${column}`) ? this.cells.get(`${row},${column}`) : ""; }
  set(row, column, value) { this.cells.set(`${row},${column}`, value); }
  format(row, column) { return this.formats.get(`${row},${column}`); }
  styleAt(row, column) { return this.styles.get(`${row},${column}`) || {}; }
  getMaxRows() { return this.maxRows; }
  getMaxColumns() { return this.maxColumns; }
  setFrozenRows(n) { this.frozen.rows = n; }
  setFrozenColumns(n) { this.frozen.columns = n; }
  setHiddenGridlines(hidden) { this.gridlinesHidden = hidden; return this; }
  getConditionalFormatRules() { return this.rules.slice(); }
  setConditionalFormatRules(rules) { this.rules = Array.from(rules); }
  // A snapshot of every value, to prove a style pass writes none.
  snapshot() { return JSON.stringify([...this.cells.entries()].sort()); }
  getLastColumn() {
    let last = 0;
    for (const [key, value] of this.cells) if (value !== "") last = Math.max(last, Number(key.split(",")[1]));
    return last;
  }
  getRange(row, column, numRows = 1, numColumns = 1) { return new FakeRange(this, row, column, numRows, numColumns); }
  select(...ranges) { this.selection = ranges.map(([row, numRows]) => new FakeRange(this, row, 2, numRows, 1)); }
  selectCell(row, column) { this.selection = [new FakeRange(this, row, column)]; }
  getActiveRangeList() { return this.selection.length ? { getRanges: () => this.selection } : null; }
  getActiveRange() { return this.selection[0] || null; }
}

// The Sheet Template layout with the roster's columns in a non-alphabetical order:
// B Card, C Archived, D Last Used, E Used. Row 8 is the header, data from row 9.
function roster() {
  return new FakeSheet({
    2: ["", "Personal Card Roster"],
    3: ["", "Last Updated: Oct 2nd, 2026"],
    8: ["", "Card", "Archived", "Last Used", "Used"],
    9: ["", "Sapphire", "", "", false],
    10: ["", "Freedom", "", "", false],
    11: ["", "", "", "", false],
    12: ["", "Venture", "Archived", "", false],
    13: ["", "Blue Cash", "", "", false]
  });
}

// A conditional-format rule as Apps Script returns it, from a fake builder.
function fakeRule(spec) {
  return {
    ...spec,
    getRanges: () => spec.ranges,
    getBooleanCondition: () => (spec.formula == null ? null : {
      getCriteriaType: () => "CUSTOM_FORMULA",
      getCriteriaValues: () => [spec.formula]
    })
  };
}

function ruleBuilder() {
  const spec = {};
  const builder = {
    whenFormulaSatisfied(f) { spec.formula = f; return builder; },
    setRanges(ranges) { spec.ranges = Array.from(ranges, (r) => r.a1()); return builder; },
    setBackground(c) { spec.background = c; return builder; },
    setFontColor(c) { spec.fontColor = c; return builder; },
    setBold(b) { spec.bold = b; return builder; },
    setItalic(b) { spec.italic = b; return builder; },
    build() { return fakeRule(spec); }
  };
  return builder;
}

function services(sheet, { now = new Date(2026, 10, 10, 21, 30), timeZone = "America/Denver" } = {}) {
  const toasts = [];
  // A menu: its items in order, a submenu as { label, items }.
  const menu = { items: [], separators: 0, added: false };
  const triggers = [];
  const zones = [];
  const spreadsheet = {
    toast: (message, title) => toasts.push({ message, title }),
    getActiveSheet: () => sheet,
    getSpreadsheetTimeZone: () => timeZone
  };
  const menuBuilder = (target) => {
    const builder = {
      addItem(label, fn) { target.items.push({ label, fn }); return builder; },
      addSeparator() { target.separators += 1; return builder; },
      addSubMenu(sub) { target.items.push(sub.menu); return builder; },
      addToUi() { target.added = true; },
      menu: target
    };
    return builder;
  };
  const globals = {
    SpreadsheetApp: {
      getActive: () => spreadsheet,
      getActiveSpreadsheet: () => spreadsheet,
      getActiveSheet: () => sheet,
      getUi: () => ({
        createAddonMenu: () => menuBuilder(menu),
        createMenu: (label) => menuBuilder({ label, items: [], separators: 0 })
      }),
      newConditionalFormatRule: ruleBuilder,
      BooleanCriteria: { CUSTOM_FORMULA: "CUSTOM_FORMULA" }
    },
    ScriptApp: {
      getUserTriggers(ss) {
        assert.equal(ss, spreadsheet, "triggers are read for the current spreadsheet");
        return triggers.slice();
      },
      newTrigger(handler) {
        const spec = { handler };
        const chain = {
          forSpreadsheet(ss) { spec.spreadsheet = ss; return chain; },
          onEdit() { spec.event = "edit"; return chain; },
          create() {
            const trigger = { ...spec, getHandlerFunction: () => handler };
            triggers.push(trigger);
            return trigger;
          }
        };
        return chain;
      },
      deleteTrigger(trigger) { triggers.splice(triggers.indexOf(trigger), 1); }
    },
    Utilities: {
      // The fake reads dates in Node's local zone and records the zone asked for.
      formatDate(date, tz, pattern) {
        zones.push(tz);
        assert.equal(pattern, "yyyy-M-d");
        return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
      },
      parseDate(text, tz, pattern) {
        zones.push(tz);
        assert.equal(pattern, "yyyy-M-d");
        const [y, m, d] = text.split("-").map(Number);
        return new Date(y, m - 1, d);
      }
    }
  };
  const addon = loadAddon(globals);
  addon.studioNow_ = () => new Date(now.getTime());
  return { addon, toasts, menu, triggers, spreadsheet, zones };
}

// The add-on builds its dates in its own V8 context, so compare by time, not instanceof.
const isFirstOfNov2026 = (value) =>
  value != null && typeof value.getTime === "function" &&
  value.getTime() === new Date(2026, 10, 1).getTime();

// --- Mark used this month ----------------------------------------------------------

test("mark used stamps the 1st of this month on selected named rows only", () => {
  const sheet = roster();
  sheet.select([7, 4], [13, 1]); // rows 7-10 and 13: 7-8 are above the data, 11 is blank
  const { addon, toasts } = services(sheet);
  addon.studioMarkUsedThisMonth();

  for (const row of [9, 10, 13]) {
    assert.ok(isFirstOfNov2026(sheet.get(row, 4)), `row ${row} Last Used`);
    assert.equal(sheet.format(row, 4), "m/yy");
  }
  assert.equal(sheet.get(11, 4), "", "a blank-name row is skipped");
  assert.equal(sheet.get(12, 4), "", "an unselected row is untouched");
  assert.equal(sheet.get(8, 4), "Last Used", "the header is never written");
  assert.equal(sheet.writes, 2, "one write per contiguous run (9-10, 13)");
  assert.deepEqual(toasts, [{ message: "3 card(s) marked used Nov 2026", title: "Studio" }]);
});

test("mark used finds Last Used by its header after the column moves", () => {
  const sheet = new FakeSheet({
    8: ["Last Used", "Card"],
    9: ["", "Sapphire"]
  });
  sheet.select([9, 1]);
  const { addon } = services(sheet);
  addon.studioMarkUsedThisMonth();
  assert.ok(isFirstOfNov2026(sheet.get(9, 1)));
});

test("mark used says so and writes nothing when there is no Last Used header", () => {
  const sheet = new FakeSheet({ 8: ["", "Card"], 9: ["", "Sapphire"] });
  sheet.select([9, 1]);
  const { addon, toasts } = services(sheet);
  addon.studioMarkUsedThisMonth();
  assert.equal(sheet.writes, 0);
  assert.equal(toasts[0].message, 'No "Last Used" header in row 8');
});

// --- Archive -------------------------------------------------------------------------

test("archive and un-archive set and clear the exact text Archived", () => {
  const sheet = roster();
  sheet.select([9, 3]);
  const { addon, toasts } = services(sheet);

  addon.studioArchiveRows();
  assert.equal(sheet.get(9, 3), "Archived");
  assert.equal(sheet.get(10, 3), "Archived");
  assert.equal(sheet.get(11, 3), "", "a blank-name row is skipped");
  assert.equal(toasts.at(-1).message, "2 row(s) archived");

  sheet.select([10, 3]);
  addon.studioUnarchiveRows();
  assert.equal(sheet.get(9, 3), "Archived");
  assert.equal(sheet.get(10, 3), "");
  assert.equal(sheet.get(12, 3), "", "Venture was selected and un-archived");
  assert.equal(toasts.at(-1).message, "2 row(s) un-archived");
});

// --- Stamp Last Updated ----------------------------------------------------------

test("stamp Last Updated rewrites the B-column line in the spreadsheet's time zone", () => {
  const sheet = roster();
  const { addon, toasts, zones } = services(sheet, { timeZone: "America/Los_Angeles" });
  addon.studioStampLastUpdated();
  assert.equal(sheet.get(3, 2), "Last Updated: Nov 10th, 2026");
  assert.equal(sheet.get(2, 2), "Personal Card Roster");
  assert.equal(toasts[0].message, "Last Updated: Nov 10th, 2026");
  assert.deepEqual(zones, ["America/Los_Angeles"]);
});

test("mark used builds the 1st of the month in the spreadsheet's time zone, not the script's", () => {
  const sheet = roster();
  sheet.select([9, 1]);
  const { addon, zones } = services(sheet, { timeZone: "America/Los_Angeles" });
  addon.studioMarkUsedThisMonth();
  assert.ok(isFirstOfNov2026(sheet.get(9, 4)));
  assert.deepEqual(zones, ["America/Los_Angeles", "America/Los_Angeles"], "format today, then parse the 1st, both in the sheet's zone");
});

test("stamp Last Updated leaves a sheet without the line alone", () => {
  const sheet = new FakeSheet({ 2: ["", "Title"], 7: ["", "Last Updated: below the scan"] });
  const { addon, toasts } = services(sheet);
  addon.studioStampLastUpdated();
  assert.equal(sheet.writes, 0);
  assert.match(toasts[0].message, /^No "Last Updated:" cell in B1:B6$/);
});

// --- The Used tick-box -------------------------------------------------------------

test("turning on the tick-box installs one onEdit trigger, never two", () => {
  const sheet = roster();
  const { addon, triggers, spreadsheet, toasts } = services(sheet);
  addon.studioTurnOnUsedTicks();
  addon.studioTurnOnUsedTicks();
  assert.equal(triggers.length, 1);
  assert.equal(triggers[0].handler, "studioOnUsedTick");
  assert.equal(triggers[0].event, "edit");
  assert.equal(triggers[0].spreadsheet, spreadsheet);
  assert.match(toasts[1].message, /already on/);

  addon.studioTurnOffUsedTicks();
  assert.equal(triggers.length, 0);
  addon.studioTurnOffUsedTicks();
  assert.match(toasts.at(-1).message, /already off/);
});

test("a tick in Used stamps Last Used on that row and clears the tick", () => {
  const sheet = roster();
  const { addon } = services(sheet);
  sheet.set(10, 5, true);
  addon.studioOnUsedTick({ range: sheet.getRange(10, 5), value: "TRUE" });
  assert.ok(isFirstOfNov2026(sheet.get(10, 4)));
  assert.equal(sheet.format(10, 4), "m/yy");
  assert.equal(sheet.get(10, 5), false);
  assert.equal(sheet.get(9, 4), "");
});

test("the tick-box ignores unticks, other columns and rows above the data", () => {
  const sheet = roster();
  const { addon } = services(sheet);

  addon.studioOnUsedTick({ range: sheet.getRange(10, 5), value: "FALSE" });
  sheet.set(9, 3, true);
  addon.studioOnUsedTick({ range: sheet.getRange(9, 3), value: "TRUE" });
  sheet.set(7, 5, true);
  addon.studioOnUsedTick({ range: sheet.getRange(7, 5), value: "TRUE" });
  addon.studioOnUsedTick({});
  addon.studioOnUsedTick(undefined);

  assert.equal(sheet.writes, 0);
  assert.equal(sheet.get(7, 5), true, "a tick above row 9 stays");
});

test("a pasted block of ticks stamps each ticked row", () => {
  const sheet = roster();
  const { addon } = services(sheet);
  sheet.set(9, 5, true);
  sheet.set(10, 5, false);
  sheet.set(13, 5, true);
  addon.studioOnUsedTick({ range: sheet.getRange(9, 4, 5, 2) });
  assert.ok(isFirstOfNov2026(sheet.get(9, 4)));
  assert.equal(sheet.get(10, 4), "");
  assert.ok(isFirstOfNov2026(sheet.get(13, 4)));
  assert.equal(sheet.get(9, 5), false);
  assert.equal(sheet.get(13, 5), false);
});

test("the tick-box does nothing on a sheet without Used and Last Used headers", () => {
  const sheet = new FakeSheet({ 8: ["", "Card", "Used"], 9: ["", "Sapphire", true] });
  const { addon } = services(sheet);
  addon.studioOnUsedTick({ range: sheet.getRange(9, 3), value: "TRUE" });
  assert.equal(sheet.writes, 0);
});

// --- Apply brand style -------------------------------------------------------------

// A sheet made from the Sheet Template: title, Last Updated, the headline, the
// two head rows with section labels, rows from 9. B Card, C gutter, D Limit,
// E Used, F Last Used, G Archived.
function templated() {
  return new FakeSheet({
    2: ["", "McRitchie Industries Cards"],
    3: ["", "Last Updated: Nov 10th, 2026"],
    4: ["", "TOTAL CREDIT"],
    5: ["", 42000],
    7: ["", "Card", "", "Terms", "", "", "Status"],
    8: ["", "Card", "", "Limit", "Used", "Last Used", "Archived"],
    9: ["", "Sapphire", "", 10000, false, "", ""],
    10: ["", "Venture", "", 5000, false, "", "Archived"]
  });
}

test("apply brand style colours the title, headline and head sections from Brands.js", () => {
  const sheet = templated();
  const { addon, toasts } = services(sheet);
  const mi = addon.STUDIO_BRANDS.MI;
  addon.studioBrandStyleMI();

  assert.deepEqual(sheet.styleAt(2, 2), { font: "Montserrat", color: mi.title, size: 16, weight: "bold", valign: "bottom" });
  assert.equal(sheet.styleAt(5, 2).color, mi.headline);
  assert.equal(sheet.styleAt(5, 2).size, 16);
  assert.equal(sheet.styleAt(4, 2).color, mi.headline);
  // Section one: B-C (the gutter wears the item's section); two: D-F; three: G.
  for (const [column, section] of [[2, 0], [3, 0], [4, 1], [6, 1], [7, 2]]) {
    assert.equal(sheet.styleAt(7, column).background, mi.sections[section].top, `row 7 col ${column}`);
    assert.equal(sheet.styleAt(8, column).background, mi.sections[section].low, `row 8 col ${column}`);
    assert.equal(sheet.styleAt(7, column).color, "#FFFFFF");
    assert.equal(sheet.styleAt(7, column).weight, "bold");
    assert.equal(sheet.styleAt(7, column).size, 10);
    assert.equal(sheet.styleAt(8, column).size, 9);
  }
  assert.equal(sheet.styleAt(7, 8).background, undefined, "nothing past the last headed column");
  assert.equal(sheet.styleAt(9, 2).background, undefined, "data rows keep their fills");
  assert.equal(sheet.styleAt(1000, 26).font, "Montserrat", "the font covers the whole tab");
  assert.deepEqual(sheet.frozen, { rows: 8, columns: 2 });
  assert.equal(sheet.gridlinesHidden, true);
  assert.equal(toasts[0].message, "Styled as McRitchie Industries: 3 head section(s)");
});

test("apply brand style writes no value, so a second run changes nothing", () => {
  const sheet = templated();
  const before = sheet.snapshot();
  const { addon } = services(sheet);
  addon.studioBrandStyleCW();
  const once = JSON.stringify([...sheet.styles.entries()].sort());
  addon.studioBrandStyleCW();
  assert.equal(sheet.snapshot(), before, "values untouched");
  assert.equal(sheet.writes, 0);
  assert.equal(JSON.stringify([...sheet.styles.entries()].sort()), once, "idempotent");
  assert.equal(sheet.styleAt(2, 2).valign, "middle", "CW's title is centred");
});

test("apply brand style splits an unlabelled head into three and skips a missing title", () => {
  const sheet = new FakeSheet({ 8: ["", "a", "b", "c", "d"], 9: ["", "x"] });
  const { addon } = services(sheet);
  const tm = addon.STUDIO_BRANDS.TM;
  addon.studioBrandStyleTM();
  assert.deepEqual([2, 3, 4, 5].map((c) => sheet.styleAt(8, c).background),
    [tm.sections[0].low, tm.sections[0].low, tm.sections[1].low, tm.sections[2].low]);
  assert.equal(sheet.styleAt(2, 2).color, undefined, "no title, no title style");
  assert.deepEqual(sheet.frozen, { rows: 8, columns: 2 });
});

// --- Age colours -------------------------------------------------------------------------

const formulas = (sheet) => sheet.rules.map((r) => r.formula);

test("age colours on Last Used add the drawer's bands, the date column cut out", () => {
  const sheet = templated();
  sheet.selectCell(12, 6);
  const { addon, toasts } = services(sheet);
  addon.studioAddAgeColours();

  assert.equal(sheet.rules.length, 9);
  assert.equal(sheet.rules[0].formula, '=$G9="Archived"', "archived ranks first");
  assert.deepEqual(sheet.rules[0].ranges, ["9,2,992,4", "9,7,992,1"]);
  assert.deepEqual(sheet.rules[1].ranges, ["9,6,992,1"]);
  for (const rule of sheet.rules.slice(2, 6)) assert.deepEqual(rule.ranges, ["9,2,992,4", "9,7,992,1"], "row bands skip F");
  for (const rule of sheet.rules.slice(6)) assert.deepEqual(rule.ranges, ["9,6,992,1"]);
  assert.equal(sheet.rules[6].background, "#CC0000");
  assert.equal(sheet.rules[6].fontColor, "#FFFFFF");
  assert.equal(sheet.rules[7].background, "#F1C232");
  assert.match(toasts[0].message, /^Age colours on "Last Used": 4 \/ 10 \/ 16 months$/);
  assert.equal(sheet.writes, 0, "no value written");
});

test("age colours replace their own rules, keep Archived first and other rules after", () => {
  const sheet = templated();
  const archived = fakeRule({ formula: '=$G9="Archived"', ranges: ["9,2,992,6"] });
  const other = fakeRule({ formula: "=$D9>9000", ranges: ["9,4,992,1"] });
  const colourScale = fakeRule({ formula: null, ranges: ["9,4,992,1"] });
  sheet.rules = [other, archived, colourScale];
  sheet.selectCell(9, 6);
  const { addon } = services(sheet);

  addon.studioAddAgeColours();
  const once = formulas(sheet);
  addon.studioAddAgeColours();
  assert.deepEqual(formulas(sheet), once, "a second run replaces, never stacks");
  assert.equal(sheet.rules.length, 1 + 7 + 2);
  assert.equal(sheet.rules[0], archived, "the existing Archived rule stays first, unchanged");
  assert.ok(sheet.rules.slice(1, 8).every((r) => r.formula.includes("EDATE(TODAY(),-")));
  assert.deepEqual(sheet.rules.slice(8), [other, colourScale], "other rules keep their order, after ours");
});

test("age colours need a headed column", () => {
  const sheet = templated();
  sheet.selectCell(9, 3); // the gutter: no row-8 header
  const { addon, toasts } = services(sheet);
  addon.studioAddAgeColours();
  assert.deepEqual(sheet.rules, []);
  assert.equal(toasts[0].message, "Select a cell in a date column with a header in row 8");
});

// --- Menu and manifest: what a clasp push ships -----------------------------------

test("the add-on menu names only public functions the project defines", () => {
  const { addon, menu } = services(roster());
  addon.onInstall({ authMode: "FULL" });
  assert.ok(menu.added);
  assert.deepEqual(menu.items.map((item) => item.label), [
    "Mark used this month", "Archive row", "Un-archive row", "Stamp Last Updated",
    "Apply brand style", "Add age colours to this column",
    "Turn on Used tick-boxes", "Turn off Used tick-boxes"
  ]);
  const brandMenu = menu.items[4];
  assert.deepEqual(brandMenu.items.map((item) => item.label),
    ["McRitchie Industries", "McRitchie Studio", "Commercial Welding", "Turf Monster"]);
  const leaves = menu.items.flatMap((item) => item.items || [item]);
  for (const { fn } of leaves) {
    assert.equal(typeof addon[fn], "function", fn);
    assert.ok(!fn.endsWith("_"), `${fn} must not be private`);
  }
  assert.equal(typeof addon[addon.STUDIO_TICK_HANDLER], "function");
});

test("every brand in Brands.js has its own Apply brand style item, named as the kit names it", () => {
  const { addon, menu } = services(roster());
  addon.onOpen({ authMode: "NONE" });
  const items = menu.items.find((item) => item.label === "Apply brand style").items;
  const brands = Object.entries(addon.STUDIO_BRANDS);
  assert.equal(items.length, brands.length);
  for (const [code, brand] of brands) {
    const item = items.find((i) => i.fn === `studioBrandStyle${code}`);
    assert.ok(item, `a menu item for ${code}`);
    assert.equal(item.label, brand.name);
  }
});

test("the manifest asks for the two narrow scopes only, on V8", () => {
  const manifest = JSON.parse(readFileSync(`${ADDON_DIR}src/appsscript.json`, "utf8"));
  assert.equal(manifest.runtimeVersion, "V8");
  assert.deepEqual(manifest.oauthScopes, [
    "https://www.googleapis.com/auth/spreadsheets.currentonly",
    "https://www.googleapis.com/auth/script.scriptapp"
  ]);
});

test("the clasp example carries no real script id and pushes src only", () => {
  const clasp = JSON.parse(readFileSync(`${ADDON_DIR}.clasp.json.example`, "utf8"));
  assert.equal(clasp.rootDir, "src");
  assert.match(clasp.scriptId, /^REPLACE_/);
  assert.match(readFileSync(`${ADDON_DIR}.gitignore`, "utf8"), /^\.clasp\.json$/m);
});
