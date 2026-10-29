// [unit] books_purpose: the /books purpose field shows, and is enabled, only
// while the line's category pick is a distribution. Run against stand-in
// elements: the rule reads data-kind and writes `hidden` and `disabled`.
import { test } from "node:test";
import assert from "node:assert/strict";

import { purposeShown, syncPurpose } from "../../app/javascript/books_purpose.js";

function form(kind) {
  const input = { disabled: true };
  const field = { hidden: true, querySelectorAll: () => [ input ] };
  const option = { getAttribute: (name) => (name === "data-kind" ? kind : null) };
  const select = { selectedOptions: kind === undefined ? [] : [ option ] };
  const root = {
    querySelector: (sel) => (sel === "[data-books-category]" ? select : sel === "[data-books-purpose]" ? field : null),
  };
  return { root, field, input };
}

test("only a distribution shows a purpose", () => {
  assert.equal(purposeShown("distribution"), true);
  for (const kind of [ "expense", "income", "asset", "contribution", "transfer", null, "" ]) {
    assert.equal(purposeShown(kind), false, String(kind));
  }
});

test("a distribution pick shows and enables the field; any other pick hides and disables it", () => {
  const dist = form("distribution");
  syncPurpose(dist.root);
  assert.deepEqual([ dist.field.hidden, dist.input.disabled ], [ false, false ]);

  const fee = form("expense");
  fee.field.hidden = false; fee.input.disabled = false;
  syncPurpose(fee.root);
  assert.deepEqual([ fee.field.hidden, fee.input.disabled ], [ true, true ]);

  const blank = form(undefined);
  syncPurpose(blank.root);
  assert.deepEqual([ blank.field.hidden, blank.input.disabled ], [ true, true ]);
});
