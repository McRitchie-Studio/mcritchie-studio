// [integration] The Studio Sheets add-on's Apps Script layer (addons/studio-sheets/
// src/Studio.js) run against an in-memory SpreadsheetApp, ScriptApp, Session and
// Utilities: the menu actions, the installable tick-box trigger, and the manifest
// and menu wiring a clasp push depends on.
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
}

class FakeSheet {
  // `rows` maps a row number to its cells from column A.
  constructor(rows = {}) {
    this.cells = new Map();
    this.formats = new Map();
    this.writes = 0;
    this.selection = [];
    for (const [row, line] of Object.entries(rows)) {
      line.forEach((value, i) => this.set(Number(row), i + 1, value));
    }
  }
  get(row, column) { return this.cells.has(`${row},${column}`) ? this.cells.get(`${row},${column}`) : ""; }
  set(row, column, value) { this.cells.set(`${row},${column}`, value); }
  format(row, column) { return this.formats.get(`${row},${column}`); }
  getLastColumn() {
    let last = 0;
    for (const [key, value] of this.cells) if (value !== "") last = Math.max(last, Number(key.split(",")[1]));
    return last;
  }
  getRange(row, column, numRows = 1, numColumns = 1) { return new FakeRange(this, row, column, numRows, numColumns); }
  select(...ranges) { this.selection = ranges.map(([row, numRows]) => new FakeRange(this, row, 2, numRows, 1)); }
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

function services(sheet, { now = new Date(2026, 10, 10, 21, 30) } = {}) {
  const toasts = [];
  const menu = { items: [], separators: 0, added: false };
  const triggers = [];
  const spreadsheet = {
    toast: (message, title) => toasts.push({ message, title }),
    getActiveSheet: () => sheet
  };
  const builder = {
    addItem(label, fn) { menu.items.push({ label, fn }); return builder; },
    addSeparator() { menu.separators += 1; return builder; },
    addToUi() { menu.added = true; }
  };
  const globals = {
    SpreadsheetApp: {
      getActive: () => spreadsheet,
      getActiveSpreadsheet: () => spreadsheet,
      getActiveSheet: () => sheet,
      getUi: () => ({ createAddonMenu: () => builder })
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
    Session: { getScriptTimeZone: () => "America/Denver" },
    Utilities: {
      formatDate(date, tz, pattern) {
        assert.equal(tz, "America/Denver");
        assert.equal(pattern, "yyyy-M-d");
        return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
      }
    }
  };
  const addon = loadAddon(globals);
  addon.studioNow_ = () => new Date(now.getTime());
  return { addon, toasts, menu, triggers, spreadsheet };
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

test("stamp Last Updated rewrites the B-column line in the script's time zone", () => {
  const sheet = roster();
  const { addon, toasts } = services(sheet);
  addon.studioStampLastUpdated();
  assert.equal(sheet.get(3, 2), "Last Updated: Nov 10th, 2026");
  assert.equal(sheet.get(2, 2), "Personal Card Roster");
  assert.equal(toasts[0].message, "Last Updated: Nov 10th, 2026");
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

// --- Menu and manifest: what a clasp push ships -----------------------------------

test("the add-on menu names only public functions the project defines", () => {
  const { addon, menu } = services(roster());
  addon.onInstall({ authMode: "FULL" });
  assert.ok(menu.added);
  assert.deepEqual(menu.items.map((item) => item.label), [
    "Mark used this month", "Archive row", "Un-archive row", "Stamp Last Updated",
    "Turn on Used tick-boxes", "Turn off Used tick-boxes"
  ]);
  for (const { fn } of menu.items) {
    assert.equal(typeof addon[fn], "function", fn);
    assert.ok(!fn.endsWith("_"), `${fn} must not be private`);
  }
  assert.equal(typeof addon[addon.STUDIO_TICK_HANDLER], "function");
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
