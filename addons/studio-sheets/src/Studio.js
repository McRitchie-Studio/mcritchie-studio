// Studio add-on: the Apps Script layer. It reads and writes the sheet through
// SpreadsheetApp and leaves every decision to the pure functions in Logic.js.
//
// Columns are found by their header names in row 8, never by letter, so a
// moved column never breaks a menu item. A name ending in "_" is private to the
// script: Apps Script never runs it from a menu or a trigger.

var STUDIO_TICK_HANDLER = 'studioOnUsedTick';

// --- Menu -------------------------------------------------------------------

// An editor add-on's menu lives under Extensions > Studio. onOpen can run in
// AuthMode.NONE, so it only builds the menu and reads nothing.
function onOpen(e) {
  SpreadsheetApp.getUi().createAddonMenu()
    .addItem('Mark used this month', 'studioMarkUsedThisMonth')
    .addItem('Archive row', 'studioArchiveRows')
    .addItem('Un-archive row', 'studioUnarchiveRows')
    .addItem('Stamp Last Updated', 'studioStampLastUpdated')
    .addSeparator()
    .addItem('Turn on Used tick-boxes', 'studioTurnOnUsedTicks')
    .addItem('Turn off Used tick-boxes', 'studioTurnOffUsedTicks')
    .addToUi();
}

// Installing from the Marketplace in an open sheet runs onInstall, not onOpen.
function onInstall(e) {
  onOpen(e);
}

// --- Menu actions -------------------------------------------------------------

// Set Last Used to the 1st of this month on every selected data row.
function studioMarkUsedThisMonth() {
  var sheet = SpreadsheetApp.getActiveSheet();
  var column = studioRequireColumn_(sheet, 'Last Used');
  if (!column) return;
  var rows = studioTargetRows_(sheet);
  var first = studioFirstOfMonth(studioNow_());
  studioWriteColumn_(sheet, rows, column, first, STUDIO_LAST_USED_FORMAT);
  studioToast_(studioMarkedUsedMessage(rows.length, first));
}

function studioArchiveRows() {
  studioSetArchived_(STUDIO_ARCHIVED_VALUE, 'archived');
}

function studioUnarchiveRows() {
  studioSetArchived_('', 'un-archived');
}

// Rewrite the "Last Updated:" line in column B (rows 1-6) to today's date.
function studioStampLastUpdated() {
  var sheet = SpreadsheetApp.getActiveSheet();
  var cells = sheet.getRange(1, STUDIO_NAME_COLUMN, STUDIO_LAST_UPDATED_SCAN_ROWS, 1).getValues()
    .map(function (row) { return row[0]; });
  var index = studioFindLastUpdated(cells);
  if (index < 0) {
    studioToast_('No "' + STUDIO_LAST_UPDATED_PREFIX + '" cell in B1:B' + STUDIO_LAST_UPDATED_SCAN_ROWS);
    return;
  }
  var parts = Utilities.formatDate(studioNow_(), Session.getScriptTimeZone(), 'yyyy-M-d')
    .split('-').map(Number);
  var text = studioLastUpdatedText(parts[0], parts[1], parts[2]);
  sheet.getRange(index + 1, STUDIO_NAME_COLUMN).setValue(text);
  studioToast_(text);
}

// --- The Used tick-box --------------------------------------------------------

// Simple onEdit triggers never run for an editor add-on, so the tick-box needs
// an installable trigger on this spreadsheet. Installing twice is a no-op.
function studioTurnOnUsedTicks() {
  var spreadsheet = SpreadsheetApp.getActive();
  if (studioTickTriggers_(spreadsheet).length > 0) {
    studioToast_('Used tick-boxes are already on for this spreadsheet');
    return;
  }
  ScriptApp.newTrigger(STUDIO_TICK_HANDLER).forSpreadsheet(spreadsheet).onEdit().create();
  studioToast_('Used tick-boxes are on: a tick stamps Last Used');
}

function studioTurnOffUsedTicks() {
  var spreadsheet = SpreadsheetApp.getActive();
  var triggers = studioTickTriggers_(spreadsheet);
  triggers.forEach(function (trigger) { ScriptApp.deleteTrigger(trigger); });
  studioToast_(triggers.length > 0 ? 'Used tick-boxes are off' : 'Used tick-boxes were already off');
}

// The installable onEdit handler: a tick in a "Used" column on a data row
// writes the 1st of this month into "Last Used" and clears the tick.
function studioOnUsedTick(e) {
  if (!e || !e.range) return;
  var range = e.range;
  if (range.getLastRow() < STUDIO_FIRST_DATA_ROW) return;
  var single = range.getNumRows() === 1 && range.getNumColumns() === 1;
  if (single && !studioIsTicked(e.value)) return;

  var sheet = range.getSheet();
  var headers = studioHeaders_(sheet);
  var usedColumn = studioColumnIndex(headers, 'Used');
  var lastUsedColumn = studioColumnIndex(headers, 'Last Used');
  if (!usedColumn || !lastUsedColumn) return;

  var rows = studioTickedRows(
    { row: range.getRow(), column: range.getColumn(), values: range.getValues() },
    usedColumn
  );
  if (rows.length === 0) return;
  var first = studioFirstOfMonth(studioNow_());
  rows.forEach(function (row) {
    sheet.getRange(row, lastUsedColumn).setValue(first).setNumberFormat(STUDIO_LAST_USED_FORMAT);
    sheet.getRange(row, usedColumn).setValue(false);
  });
}

// --- Helpers ------------------------------------------------------------------

// The clock, in one place so the tests can fix it.
function studioNow_() {
  return new Date();
}

function studioToast_(message) {
  SpreadsheetApp.getActive().toast(message, 'Studio');
}

function studioHeaders_(sheet) {
  var width = sheet.getLastColumn();
  if (width < 1) return [];
  return sheet.getRange(STUDIO_HEADER_ROW, 1, 1, width).getValues()[0];
}

// The column headed `name`, or 0 after telling the user it is missing.
function studioRequireColumn_(sheet, name) {
  var column = studioColumnIndex(studioHeaders_(sheet), name);
  if (!column) studioToast_('No "' + name + '" header in row ' + STUDIO_HEADER_ROW);
  return column;
}

// The selected data rows (every range of a multi-range selection) whose
// column B is filled.
function studioTargetRows_(sheet) {
  var list = sheet.getActiveRangeList();
  var ranges = list ? list.getRanges() : [sheet.getActiveRange()];
  var rows = studioSelectedRows(ranges.filter(Boolean).map(function (range) {
    return { row: range.getRow(), numRows: range.getNumRows() };
  }));
  if (rows.length === 0) return [];
  var top = rows[0];
  var names = sheet.getRange(top, STUDIO_NAME_COLUMN, rows[rows.length - 1] - top + 1, 1).getValues();
  return studioRowsWithNames(rows, function (row) { return names[row - top][0]; });
}

// Write one value into `column` on each row, one range write per contiguous run.
function studioWriteColumn_(sheet, rows, column, value, numberFormat) {
  studioRuns(rows).forEach(function (run) {
    var range = sheet.getRange(run.row, column, run.numRows, 1);
    var values = [];
    for (var i = 0; i < run.numRows; i++) values.push([value]);
    range.setValues(values);
    if (numberFormat) range.setNumberFormat(numberFormat);
  });
}

function studioSetArchived_(value, verb) {
  var sheet = SpreadsheetApp.getActiveSheet();
  var column = studioRequireColumn_(sheet, 'Archived');
  if (!column) return;
  var rows = studioTargetRows_(sheet);
  studioWriteColumn_(sheet, rows, column, value, null);
  studioToast_(rows.length + ' row(s) ' + verb);
}

function studioTickTriggers_(spreadsheet) {
  return ScriptApp.getUserTriggers(spreadsheet).filter(function (trigger) {
    return trigger.getHandlerFunction() === STUDIO_TICK_HANDLER;
  });
}
