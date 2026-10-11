// [unit] theme_context.js (task logo-gallery-polish-pass): a page whose root names its theme is put in that theme
// before the first paint, and the theme is stored, as the engine's store reads it. A classic script, so it is run
// here as the browser runs it: as source, in a context with a document and localStorage.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const SOURCE = readFileSync(new URL("../../app/javascript/theme_context.js", import.meta.url), "utf8");

function run({ theme, dark, storage = {} , blocked = false }) {
  const classes = new Set(dark ? ["dark"] : []);
  const root = {
    getAttribute: (name) => (name === "data-theme-context" ? theme : null),
    classList: { toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)) },
  };
  const localStorage = { setItem: (k, v) => { if (blocked) throw new Error("SecurityError"); storage[k] = v; } };
  vm.runInNewContext(SOURCE, { document: { documentElement: root }, localStorage });
  return { dark: classes.has("dark"), storage };
}

test("a light page turns a stored dark theme light, and stores light", () => {
  assert.deepEqual(run({ theme: "light", dark: true, storage: { theme: "dark" } }), { dark: false, storage: { theme: "light" } });
});

test("a dark page turns a stored light theme dark, and stores dark", () => {
  assert.deepEqual(run({ theme: "dark", dark: false, storage: { theme: "light" } }), { dark: true, storage: { theme: "dark" } });
});

test("a page that names no theme, or an unknown one, is left alone", () => {
  assert.deepEqual(run({ theme: null, dark: true, storage: { theme: "dark" } }), { dark: true, storage: { theme: "dark" } });
  assert.deepEqual(run({ theme: "watermark", dark: false, storage: {} }), { dark: false, storage: {} });
});

test("with storage blocked, the class still follows the page", () => {
  assert.equal(run({ theme: "light", dark: true, blocked: true }).dark, false);
});
