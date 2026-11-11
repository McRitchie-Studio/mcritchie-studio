// [unit] The Studio Sheets add-on's pure logic (addons/studio-sheets/src/Logic.js):
// header lookup, the ordinal date, row selection and filtering.
import { test } from "node:test";
import assert from "node:assert/strict";

import { loadAddon } from "./support/studio_sheets_addon.mjs";

const logic = loadAddon({}, ["Logic.js"]);
const plain = (value) => JSON.parse(JSON.stringify(value));

test("a header is found by name wherever its column sits, trimmed", () => {
  const headers = ["", "Card", "Used", " Last Used ", "Archived"];
  assert.equal(logic.studioColumnIndex(headers, "Card"), 2);
  assert.equal(logic.studioColumnIndex(headers, "Last Used"), 4);
  assert.equal(logic.studioColumnIndex(headers, "Archived"), 5);
  const moved = ["Last Used", "Card", "Archived", "Used"];
  assert.equal(logic.studioColumnIndex(moved, "Last Used"), 1);
  assert.equal(logic.studioColumnIndex(moved, "Used"), 4);
});

test("a missing header is 0, and Used never matches Last Used", () => {
  assert.equal(logic.studioColumnIndex(["Card", "Last Used"], "Used"), 0);
  assert.equal(logic.studioColumnIndex([], "Used"), 0);
  assert.equal(logic.studioColumnIndex([null, 7, "used"], "Used"), 0);
});

test("ordinals follow English, teens included", () => {
  const expected = { 1: "1st", 2: "2nd", 3: "3rd", 4: "4th", 10: "10th", 11: "11th", 12: "12th",
    13: "13th", 21: "21st", 22: "22nd", 23: "23rd", 30: "30th", 31: "31st" };
  for (const [day, text] of Object.entries(expected)) {
    assert.equal(logic.studioOrdinal(Number(day)), text);
  }
});

test("the Last Updated line is short month, ordinal day, year", () => {
  assert.equal(logic.studioLastUpdatedText(2026, 11, 10), "Last Updated: Nov 10th, 2026");
  assert.equal(logic.studioLastUpdatedText(2027, 1, 1), "Last Updated: Jan 1st, 2027");
  assert.equal(logic.studioLastUpdatedText(2026, 9, 22), "Last Updated: Sep 22nd, 2026");
});

test("the Last Updated cell is the first that starts with the prefix", () => {
  assert.equal(logic.studioFindLastUpdated(["Card Roster", "", "Last Updated: Oct 1st, 2026"]), 2);
  assert.equal(logic.studioFindLastUpdated(["  Last Updated: x", "Last Updated: y"]), 0);
  assert.equal(logic.studioFindLastUpdated(["Updated: Oct", 42, null, "last updated:"]), -1);
});

test("selected rows are unique, ascending, and never above the first data row", () => {
  const rows = logic.studioSelectedRows([{ row: 12, numRows: 2 }, { row: 5, numRows: 6 }, { row: 13, numRows: 1 }]);
  assert.deepEqual(plain(rows), [9, 10, 12, 13]);
  assert.deepEqual(plain(logic.studioSelectedRows([{ row: 1, numRows: 8 }])), []);
  assert.deepEqual(plain(logic.studioSelectedRows([])), []);
});

test("rows with a blank name cell are skipped", () => {
  const names = { 9: "Sapphire", 10: "", 11: "  ", 12: 0, 13: null };
  assert.deepEqual(plain(logic.studioRowsWithNames([9, 10, 11, 12, 13], (row) => names[row])), [9, 12]);
});

test("rows group into contiguous runs", () => {
  assert.deepEqual(plain(logic.studioRuns([9, 10, 11, 14, 16, 17])),
    [{ row: 9, numRows: 3 }, { row: 14, numRows: 1 }, { row: 16, numRows: 2 }]);
  assert.deepEqual(plain(logic.studioRuns([])), []);
});

test("a tick is the event's TRUE string or a boolean true, nothing else", () => {
  assert.equal(logic.studioIsTicked("TRUE"), true);
  assert.equal(logic.studioIsTicked(true), true);
  for (const value of ["FALSE", false, "true", 1, "", undefined]) {
    assert.equal(logic.studioIsTicked(value), false, String(value));
  }
});

test("ticked rows come only from the Used column on data rows", () => {
  const edit = { row: 8, column: 3, values: [[true, true], [true, false], ["TRUE", true], [false, true]] };
  assert.deepEqual(plain(logic.studioTickedRows(edit, 3)), [9, 10]);
  assert.deepEqual(plain(logic.studioTickedRows(edit, 4)), [10, 11]);
  assert.deepEqual(plain(logic.studioTickedRows(edit, 5)), []);
  assert.deepEqual(plain(logic.studioTickedRows(edit, 2)), []);
  assert.deepEqual(plain(logic.studioTickedRows(edit, 0)), []);
});

test("the mark-used toast names the count and the month", () => {
  assert.equal(logic.studioMarkedUsedMessage(3, 2026, 11), "3 card(s) marked used Nov 2026");
  assert.equal(logic.studioMarkedUsedMessage(0, 2027, 1), "0 card(s) marked used Jan 2027");
});
