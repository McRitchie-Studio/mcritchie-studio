// Studio add-on: the pure logic. Nothing here touches SpreadsheetApp, so the
// Node tests (test/javascript/studio_sheets_*_test.js) load this file unchanged.
//
// Apps Script shares one global scope across a project's files, so these are
// plain function declarations, never modules. Studio.js is the thin layer that
// reads and writes the sheet with them.

// The Sheet Template layout: the table header is row 8, data starts row 9, and
// column B holds the row's name (a blank B is an empty row).
var STUDIO_HEADER_ROW = 8;
var STUDIO_FIRST_DATA_ROW = 9;
var STUDIO_NAME_COLUMN = 2;
var STUDIO_ARCHIVED_VALUE = 'Archived';
var STUDIO_LAST_USED_FORMAT = 'm/yy';
var STUDIO_LAST_UPDATED_PREFIX = 'Last Updated:';
var STUDIO_LAST_UPDATED_SCAN_ROWS = 6;
var STUDIO_SHORT_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// The 1-based column whose header is `name`, or 0 when no header matches.
// Headers are compared after trimming, so a stray space never hides a column.
function studioColumnIndex(headers, name) {
  var wanted = String(name).trim();
  for (var i = 0; i < headers.length; i++) {
    if (String(headers[i] == null ? '' : headers[i]).trim() === wanted) return i + 1;
  }
  return 0;
}

// Midnight on the 1st of the month that `now` falls in (local time).
function studioFirstOfMonth(now) {
  return new Date(now.getFullYear(), now.getMonth(), 1);
}

// 1 -> "1st", 2 -> "2nd", 11 -> "11th", 22 -> "22nd".
function studioOrdinal(day) {
  var teen = day % 100;
  if (teen >= 11 && teen <= 13) return day + 'th';
  switch (day % 10) {
    case 1: return day + 'st';
    case 2: return day + 'nd';
    case 3: return day + 'rd';
    default: return day + 'th';
  }
}

// "Last Updated: Nov 10th, 2026" from a year, a 1-based month and a day.
function studioLastUpdatedText(year, month, day) {
  return STUDIO_LAST_UPDATED_PREFIX + ' ' + STUDIO_SHORT_MONTHS[month - 1] + ' ' +
    studioOrdinal(day) + ', ' + year;
}

// The 0-based index of the first value that starts with "Last Updated:", or -1.
function studioFindLastUpdated(values) {
  for (var i = 0; i < values.length; i++) {
    if (typeof values[i] === 'string' && values[i].trim().indexOf(STUDIO_LAST_UPDATED_PREFIX) === 0) {
      return i;
    }
  }
  return -1;
}

// The data rows a selection covers: `ranges` is [{row, numRows}], possibly
// overlapping. Returns unique row numbers >= the first data row, ascending.
function studioSelectedRows(ranges) {
  var seen = {};
  var rows = [];
  for (var i = 0; i < ranges.length; i++) {
    var start = Math.max(ranges[i].row, STUDIO_FIRST_DATA_ROW);
    var end = ranges[i].row + ranges[i].numRows - 1;
    for (var row = start; row <= end; row++) {
      if (!seen[row]) {
        seen[row] = true;
        rows.push(row);
      }
    }
  }
  return rows.sort(function (a, b) { return a - b; });
}

// Keep the rows whose name cell is filled. `nameAt(row)` returns column B's
// value for that row.
function studioRowsWithNames(rows, nameAt) {
  return rows.filter(function (row) {
    var name = nameAt(row);
    return name !== '' && name !== null && name !== undefined &&
      String(name).trim() !== '';
  });
}

// Group ascending row numbers into contiguous runs: [9,10,12] -> [{row: 9,
// numRows: 2}, {row: 12, numRows: 1}], so each run is one range write.
function studioRuns(rows) {
  var runs = [];
  for (var i = 0; i < rows.length; i++) {
    var last = runs[runs.length - 1];
    if (last && rows[i] === last.row + last.numRows) {
      last.numRows += 1;
    } else {
      runs.push({ row: rows[i], numRows: 1 });
    }
  }
  return runs;
}

// True for a ticked checkbox, whether it arrives as the event's "TRUE" string
// or a range's boolean.
function studioIsTicked(value) {
  return value === true || value === 'TRUE';
}

// The rows an edit ticked in the Used column. `edit` is the edited block
// ({row, column, values}, values a 2-D array); `usedColumn` is 1-based.
function studioTickedRows(edit, usedColumn) {
  var offset = usedColumn - edit.column;
  if (usedColumn < 1 || offset < 0 || offset >= (edit.values[0] || []).length) return [];
  var rows = [];
  for (var i = 0; i < edit.values.length; i++) {
    var row = edit.row + i;
    if (row >= STUDIO_FIRST_DATA_ROW && studioIsTicked(edit.values[i][offset])) rows.push(row);
  }
  return rows;
}

// "3 card(s) marked used Nov 2026".
function studioMarkedUsedMessage(count, firstOfMonth) {
  return count + ' card(s) marked used ' + STUDIO_SHORT_MONTHS[firstOfMonth.getMonth()] +
    ' ' + firstOfMonth.getFullYear();
}
