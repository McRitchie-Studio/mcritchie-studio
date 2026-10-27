// [unit] The node:test hook's prefixes come from config/importmap.rb
// (test/javascript/support/register.mjs), so the test resolver and the browser's
// importmap cannot disagree about where "board/*" lives.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { importmapPrefixes } from "./support/importmap_prefixes.mjs";

test("each pin_all_from ... under: line becomes one prefix", () => {
  const source = [
    'pin "application"',
    'pin_all_from "app/javascript/board", under: "board"',
    "  pin_all_from 'app/javascript/kit/', under: 'kit' # trailing comment",
    'pin_all_from "app/javascript/controllers", under: "controllers", preload: false',
  ].join("\n");
  assert.deepEqual(importmapPrefixes(source), {
    board: "app/javascript/board/",
    kit: "app/javascript/kit/",
    controllers: "app/javascript/controllers/",
  });
});

test("a commented-out line and a pin_all_from with no prefix map nothing", () => {
  assert.deepEqual(importmapPrefixes('# pin_all_from "x", under: "x"\npin_all_from "app/javascript/y"\n'), {});
});

test("the hub's own importmap maps board onto app/javascript/board", () => {
  const source = readFileSync(new URL("../../config/importmap.rb", import.meta.url), "utf8");
  assert.equal(importmapPrefixes(source).board, "app/javascript/board/");
});

test("a module importing board/* resolves through the hook to the importmap's directory", async () => {
  const colors = await import("board/colors");
  assert.ok(Object.keys(colors).length > 0, "board/colors exported nothing");
});
