// Studio add-on: the pure rules for Apply brand style and age colours. Nothing
// here touches SpreadsheetApp; Studio.js applies what these return.
//
// The rules are the Sheet Template drawer's (script/marketing_kit/office.py,
// def sheet): the brand colours come from Brands.js, which
// script/marketing_kit/addon_brands.rb generates from the kit specs, and the age
// bands below are the drawer's age_bands, colour for colour.

// The template's rows: title in B2, Last Updated in B3, the headline's label in
// B4 over its value in B5, the two head rows 7 and 8, data from row 9. The
// freeze holds rows 1-8 and columns A-B (C9).
var STUDIO_TITLE_ROW = 2;
var STUDIO_HEADLINE_LABEL_ROW = 4;
var STUDIO_HEADLINE_ROW = 5;
var STUDIO_HEAD_TOP_ROW = 7;
var STUDIO_TABLE_COLUMN = 2;
var STUDIO_FROZEN_ROWS = 8;
var STUDIO_FROZEN_COLUMNS = 2;

// The drawer's age_bands: { months: [fresh, neutral, warn], fresh: markers }.
// Rows: green within months[0] (or a fresh marker), white within months[1],
// yellow within months[2], red older. The date cell itself: deep red past
// months[2], amber past months[1], green while fresh.
var STUDIO_AGE_BANDS = {
  months: [4, 10, 16],
  fresh: ['💳', '🔄'],
  rows: ['#D9EAD3', '#FFFFFF', '#FFF2CC', '#F4CCCC'],
  cell: {
    old: { background: '#CC0000', fontColor: '#FFFFFF', bold: true },
    warn: { background: '#F1C232', bold: true },
    fresh: { background: '#D9EAD3' }
  }
};

// The brand row for a short code (MI, MS, CW, TM), or null.
function studioBrand(code) {
  return Object.prototype.hasOwnProperty.call(STUDIO_BRANDS, code) ? STUDIO_BRANDS[code] : null;
}

// Apps Script names vertical alignment top, middle or bottom; the kit says center.
function studioVerticalAlignment(titleAlign) {
  return titleAlign === 'bottom' ? 'bottom' : titleAlign === 'top' ? 'top' : 'middle';
}

function studioFilled(value) {
  return value !== '' && value !== null && value !== undefined && String(value).trim() !== '';
}

// The head's sections as 1-based column spans [{start, end, section}], from the
// table's first column (B) to its last headed column. `top` and `low` are rows 7
// and 8 from column A. A section runs from a labelled row-7 cell to the cell
// before the next label; columns before the first label join the first section.
// With no labels, the table's columns split into three spans, as even as they go,
// the first ones the widest. A fourth label and on reuse the colours in turn.
function studioSectionSpans(top, low) {
  var last = 0;
  var labels = [];
  var width = Math.max(top.length, low.length);
  for (var i = STUDIO_TABLE_COLUMN - 1; i < width; i++) {
    if (studioFilled(top[i]) || studioFilled(low[i])) last = i + 1;
    if (studioFilled(top[i])) labels.push(i + 1);
  }
  if (last === 0) return [];

  var spans = [];
  if (labels.length > 0) {
    for (var j = 0; j < labels.length; j++) {
      spans.push({
        start: j === 0 ? STUDIO_TABLE_COLUMN : labels[j],
        end: j + 1 < labels.length ? labels[j + 1] - 1 : last,
        section: j % 3
      });
    }
    return spans;
  }

  var count = last - STUDIO_TABLE_COLUMN + 1;
  var parts = Math.min(3, count);
  var start = STUDIO_TABLE_COLUMN;
  for (var k = 0; k < parts; k++) {
    var size = Math.floor(count / parts) + (k < count % parts ? 1 : 0);
    spans.push({ start: start, end: start + size - 1, section: k });
    start += size;
  }
  return spans;
}

// 1 -> "A", 27 -> "AA".
function studioColumnLetter(column) {
  var letters = '';
  while (column > 0) {
    var rem = (column - 1) % 26;
    letters = String.fromCharCode(65 + rem) + letters;
    column = Math.floor((column - 1) / 26);
  }
  return letters;
}

// The custom formula an archived row matches: `$G9="Archived"`.
function studioArchivedFormula(archivedColumn, firstRow) {
  return '=$' + studioColumnLetter(archivedColumn) + firstRow + '="' + STUDIO_ARCHIVED_VALUE + '"';
}

function studioIsArchivedFormula(formula) {
  return typeof formula === 'string' && formula.indexOf('="' + STUDIO_ARCHIVED_VALUE + '"') >= 0;
}

// True for a rule the age colours made (here or in the drawer): every one of them
// compares against EDATE(TODAY(), -months).
function studioIsAgeFormula(formula) {
  return typeof formula === 'string' && formula.indexOf('EDATE(TODAY(),-') >= 0;
}

// The age colours' conditional-format rules as plain data, first to last (the
// first rule that matches a cell wins). `t` holds the 1-based ageColumn,
// firstColumn, lastColumn, firstRow, lastRow, and archivedColumn (0 for none),
// with addArchived true when no Archived rule exists yet. Each rule is
// {ranges: [{row, column, numRows, numColumns}], formula, background,
// fontColor, bold, italic}. The date column is cut out of the row ranges, so a
// row rule never overlaps the cell's own rules.
function studioAgeRules(t) {
  var bands = STUDIO_AGE_BANDS;
  var numRows = t.lastRow - t.firstRow + 1;
  var block = function (from, to) {
    return { row: t.firstRow, column: from, numRows: numRows, numColumns: to - from + 1 };
  };
  var rowRanges = [];
  if (t.ageColumn > t.firstColumn) rowRanges.push(block(t.firstColumn, t.ageColumn - 1));
  if (t.ageColumn < t.lastColumn) rowRanges.push(block(t.ageColumn + 1, t.lastColumn));
  var cellRanges = [block(t.ageColumn, t.ageColumn)];

  var v = '$' + studioColumnLetter(t.ageColumn) + t.firstRow;
  var dated = function (op, months) {
    return 'AND(ISNUMBER(' + v + '),' + v + op + 'EDATE(TODAY(),-' + months + '))';
  };
  var fresh = bands.fresh.map(function (marker) { return v + '="' + marker + '",'; }).join('');
  var good = 'OR(' + fresh + dated('>=', bands.months[0]) + ')';

  var rules = [];
  if (t.archivedColumn && t.addArchived) {
    var grey = {
      formula: studioArchivedFormula(t.archivedColumn, t.firstRow),
      background: STUDIO_SHEET_COLOURS.light, fontColor: STUDIO_SHEET_COLOURS.grey, italic: true
    };
    if (rowRanges.length) rules.push(studioRule_(rowRanges, grey));
    rules.push(studioRule_(cellRanges, grey));
  }
  if (rowRanges.length) {
    [good, dated('>=', bands.months[1]), dated('>=', bands.months[2]), dated('<', bands.months[2])]
      .forEach(function (formula, i) {
        rules.push(studioRule_(rowRanges, { formula: '=' + formula, background: bands.rows[i] }));
      });
  }
  [[dated('<', bands.months[2]), bands.cell.old], [dated('<', bands.months[1]), bands.cell.warn], [good, bands.cell.fresh]]
    .forEach(function (pair) {
      var style = pair[1];
      rules.push(studioRule_(cellRanges, {
        formula: '=' + pair[0], background: style.background, fontColor: style.fontColor, bold: style.bold
      }));
    });
  return rules;
}

function studioRule_(ranges, style) {
  return {
    ranges: ranges,
    formula: style.formula,
    background: style.background || null,
    fontColor: style.fontColor || null,
    bold: style.bold === true,
    italic: style.italic === true
  };
}

// Where each existing rule goes when the age colours are applied: `formulas` are
// the existing rules' custom formulas (null for a rule that is not one). Returns
// {archived, others}: the indices of the Archived rules (kept, ranked first) and
// of the other rules (kept, ranked after the age colours). A rule the age colours
// made before is in neither, so a second run replaces it rather than stacking.
function studioSortExistingRules(formulas) {
  var archived = [];
  var others = [];
  for (var i = 0; i < formulas.length; i++) {
    if (studioIsArchivedFormula(formulas[i])) archived.push(i);
    else if (!studioIsAgeFormula(formulas[i])) others.push(i);
  }
  return { archived: archived, others: others };
}
