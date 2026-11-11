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
  var ui = SpreadsheetApp.getUi();
  ui.createAddonMenu()
    .addItem('Mark used this month', 'studioMarkUsedThisMonth')
    .addItem('Archive row', 'studioArchiveRows')
    .addItem('Un-archive row', 'studioUnarchiveRows')
    .addItem('Stamp Last Updated', 'studioStampLastUpdated')
    .addSeparator()
    .addSubMenu(studioBrandMenu_(ui))
    .addItem('Add age colours to this column', 'studioAddAgeColours')
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
  var today = studioToday_();
  studioWriteColumn_(sheet, rows, column, studioFirstOfMonth_(today), STUDIO_LAST_USED_FORMAT);
  studioToast_(studioMarkedUsedMessage(rows.length, today.year, today.month));
}

function studioArchiveRows() {
  studioSetArchived_(STUDIO_ARCHIVED_VALUE, 'archived');
}

function studioUnarchiveRows() {
  studioSetArchived_('', 'un-archived');
}

// Rewrite the "Last Updated:" line in column B (rows 1-6) to today's date in the
// spreadsheet's time zone.
function studioStampLastUpdated() {
  var sheet = SpreadsheetApp.getActiveSheet();
  var cells = sheet.getRange(1, STUDIO_NAME_COLUMN, STUDIO_LAST_UPDATED_SCAN_ROWS, 1).getValues()
    .map(function (row) { return row[0]; });
  var index = studioFindLastUpdated(cells);
  if (index < 0) {
    studioToast_('No "' + STUDIO_LAST_UPDATED_PREFIX + '" cell in B1:B' + STUDIO_LAST_UPDATED_SCAN_ROWS);
    return;
  }
  var today = studioToday_();
  var text = studioLastUpdatedText(today.year, today.month, today.day);
  sheet.getRange(index + 1, STUDIO_NAME_COLUMN).setValue(text);
  studioToast_(text);
}

// --- Apply brand style ----------------------------------------------------------

// One menu item per brand in Brands.js. Choosing the brand by hand means the
// add-on never reads who the user is, so it needs no userinfo scope.
var STUDIO_BRAND_MENU = [
  ['McRitchie Industries', 'studioBrandStyleMI'],
  ['McRitchie Studio', 'studioBrandStyleMS'],
  ['Commercial Welding', 'studioBrandStyleCW'],
  ['Turf Monster', 'studioBrandStyleTM']
];

function studioBrandMenu_(ui) {
  var menu = ui.createMenu('Apply brand style');
  STUDIO_BRAND_MENU.forEach(function (item) { menu.addItem(item[0], item[1]); });
  return menu;
}

function studioBrandStyleMI() { studioApplyBrandStyle_('MI'); }
function studioBrandStyleMS() { studioApplyBrandStyle_('MS'); }
function studioBrandStyleCW() { studioApplyBrandStyle_('CW'); }
function studioBrandStyleTM() { studioApplyBrandStyle_('TM'); }

// Style the active tab to the Sheet Template as far as it already has the
// layout: the font, the title in B2, the headline in B4:B5, the two head rows in
// the brand's three section colours, the freeze at C9 and no gridlines. It sets
// formats only: it never writes a value and never merges a cell.
function studioApplyBrandStyle_(code) {
  var brand = studioBrand(code);
  if (!brand) {
    studioToast_('No brand ' + code + ' in Brands.js');
    return;
  }
  var sheet = SpreadsheetApp.getActiveSheet();
  sheet.getRange(1, 1, sheet.getMaxRows(), sheet.getMaxColumns()).setFontFamily(brand.font);

  var top = sheet.getRange(1, STUDIO_TABLE_COLUMN, STUDIO_HEADLINE_ROW, 1).getValues()
    .map(function (row) { return row[0]; });
  if (studioFilled(top[STUDIO_TITLE_ROW - 1])) {
    sheet.getRange(STUDIO_TITLE_ROW, STUDIO_TABLE_COLUMN).setFontColor(brand.title).setFontSize(16)
      .setFontWeight('bold').setVerticalAlignment(studioVerticalAlignment(brand.titleAlign));
  }
  if (studioFilled(top[STUDIO_HEADLINE_ROW - 1])) {
    sheet.getRange(STUDIO_HEADLINE_LABEL_ROW, STUDIO_TABLE_COLUMN).setFontColor(brand.headline);
    sheet.getRange(STUDIO_HEADLINE_ROW, STUDIO_TABLE_COLUMN).setFontColor(brand.headline).setFontSize(16)
      .setFontWeight('bold');
  }

  var width = sheet.getLastColumn();
  var heads = width >= STUDIO_TABLE_COLUMN
    ? sheet.getRange(STUDIO_HEAD_TOP_ROW, 1, 2, width).getValues() : [[], []];
  var spans = studioSectionSpans(heads[0], heads[1]);
  spans.forEach(function (span) {
    var colours = brand.sections[span.section];
    var columns = span.end - span.start + 1;
    sheet.getRange(STUDIO_HEAD_TOP_ROW, span.start, 1, columns).setBackground(colours.top)
      .setFontColor(STUDIO_SHEET_COLOURS.white).setFontWeight('bold').setFontSize(10);
    sheet.getRange(STUDIO_HEADER_ROW, span.start, 1, columns).setBackground(colours.low)
      .setFontColor(STUDIO_SHEET_COLOURS.white).setFontWeight('bold').setFontSize(9);
  });

  sheet.setFrozenRows(STUDIO_FROZEN_ROWS);
  sheet.setFrozenColumns(STUDIO_FROZEN_COLUMNS);
  sheet.setHiddenGridlines(true);
  studioToast_('Styled as ' + brand.name + ': ' + spans.length + ' head section(s)');
}

// --- Age colours ----------------------------------------------------------------

// Colour the table by the age of the selected column's dates, the drawer's
// age_bands. It keeps an Archived rule first, replaces the age rules it (or the
// drawer) made before, and keeps every other rule after its own.
function studioAddAgeColours() {
  var sheet = SpreadsheetApp.getActiveSheet();
  var range = sheet.getActiveRange();
  var headers = studioHeaders_(sheet);
  var column = range ? range.getColumn() : 0;
  if (!column || !studioFilled(headers[column - 1])) {
    studioToast_('Select a cell in a date column with a header in row ' + STUDIO_HEADER_ROW);
    return;
  }
  var lastColumn = column;
  headers.forEach(function (header, i) { if (studioFilled(header)) lastColumn = Math.max(lastColumn, i + 1); });
  var lastRow = sheet.getMaxRows();
  if (lastRow < STUDIO_FIRST_DATA_ROW) {
    studioToast_('No data rows below row ' + STUDIO_HEADER_ROW);
    return;
  }

  var existing = sheet.getConditionalFormatRules();
  var sorted = studioSortExistingRules(existing.map(studioRuleFormula_));
  var specs = studioAgeRules({
    ageColumn: column, firstColumn: STUDIO_TABLE_COLUMN, lastColumn: lastColumn,
    firstRow: STUDIO_FIRST_DATA_ROW, lastRow: lastRow,
    archivedColumn: studioColumnIndex(headers, 'Archived'), addArchived: sorted.archived.length === 0
  });
  var pick = function (i) { return existing[i]; };
  sheet.setConditionalFormatRules(sorted.archived.map(pick)
    .concat(specs.map(function (spec) { return studioBuildRule_(sheet, spec); }))
    .concat(sorted.others.map(pick)));
  studioToast_('Age colours on "' + String(headers[column - 1]).trim() + '": ' +
    STUDIO_AGE_BANDS.months.join(' / ') + ' months');
}

// A rule's custom formula, or null for any other kind of rule.
function studioRuleFormula_(rule) {
  var condition = rule.getBooleanCondition();
  if (!condition || condition.getCriteriaType() !== SpreadsheetApp.BooleanCriteria.CUSTOM_FORMULA) return null;
  return condition.getCriteriaValues()[0];
}

function studioBuildRule_(sheet, spec) {
  var builder = SpreadsheetApp.newConditionalFormatRule()
    .whenFormulaSatisfied(spec.formula)
    .setRanges(spec.ranges.map(function (r) {
      return sheet.getRange(r.row, r.column, r.numRows, r.numColumns);
    }));
  if (spec.background) builder.setBackground(spec.background);
  if (spec.fontColor) builder.setFontColor(spec.fontColor);
  if (spec.bold) builder.setBold(true);
  if (spec.italic) builder.setItalic(true);
  return builder.build();
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
  var first = studioFirstOfMonth_(studioToday_());
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

// Today's {year, month, day} in the spreadsheet's own time zone, not the
// script's (America/Denver): a sheet kept in another zone gets its own date.
function studioToday_() {
  var parts = Utilities.formatDate(studioNow_(), studioTimeZone_(), 'yyyy-M-d').split('-').map(Number);
  return { year: parts[0], month: parts[1], day: parts[2] };
}

function studioTimeZone_() {
  return SpreadsheetApp.getActive().getSpreadsheetTimeZone();
}

// Midnight on the 1st of `today`'s month in the spreadsheet's time zone, so a
// cell formatted m/yy shows this month wherever the sheet is kept.
function studioFirstOfMonth_(today) {
  return Utilities.parseDate(today.year + '-' + today.month + '-1', studioTimeZone_(), 'yyyy-M-d');
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
