// [unit] logo_gallery: the logo gallery's Context control drives the hub theme
// (task brand-gallery-palette-and-theme). The rules read a theme and a choice and
// answer what to show, whether to flip the theme and whether to load the page.
import { test } from "node:test";
import assert from "node:assert/strict";

import { contextShown, choice, setTheme } from "../../app/javascript/logo_gallery.js";

function root(dark) {
  const classes = new Set(dark ? ["dark"] : []);
  return { classList: { contains: (c) => classes.has(c), toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)) }, classes };
}

function storage() {
  const items = {};
  return { items, setItem: (k, v) => { items[k] = v; } };
}

test("the control shows the theme the page is in, or the watermark on a watermark page", () => {
  assert.equal(contextShown(false, true), "dark");
  assert.equal(contextShown(false, false), "light");
  assert.equal(contextShown(true, true), "watermark");
  assert.equal(contextShown(true, false), "watermark");
});

test("Light and Dark flip the theme only when it differs, and never load the page", () => {
  assert.deepEqual(choice("dark", { watermarkPage: false, dark: false }), { toggle: true, load: null });
  assert.deepEqual(choice("dark", { watermarkPage: false, dark: true }), { toggle: false, load: null });
  assert.deepEqual(choice("light", { watermarkPage: false, dark: true }), { toggle: true, load: null });
  assert.deepEqual(choice("light", { watermarkPage: false, dark: false }), { toggle: false, load: null });
});

test("Watermark turns the theme dark and loads the watermark", () => {
  assert.deepEqual(choice("watermark", { watermarkPage: false, dark: false }), { toggle: true, load: "watermark" });
  assert.deepEqual(choice("watermark", { watermarkPage: false, dark: true }), { toggle: false, load: "watermark" });
});

test("leaving a watermark page loads it plain, light flipping the theme and dark keeping it", () => {
  assert.deepEqual(choice("light", { watermarkPage: true, dark: true }), { toggle: true, load: "plain" });
  assert.deepEqual(choice("dark", { watermarkPage: true, dark: true }), { toggle: false, load: "plain" });
});

test("setTheme uses the Alpine store's toggle, the moon icon's switch, when there is one", () => {
  let toggled = 0;
  const r = root(false);
  setTheme(true, { root: r, storage: storage(), store: { toggle: () => { toggled += 1; r.classList.toggle("dark", true); } } });
  assert.equal(toggled, 1);
  setTheme(true, { root: r, storage: storage(), store: { toggle: () => { toggled += 1; } } });
  assert.equal(toggled, 1, "no flip when the theme already matches");
});

test("setTheme without a store sets the root's class and stores the theme, as the engine's head reads it", () => {
  const r = root(true);
  const s = storage();
  setTheme(false, { root: r, storage: s, store: undefined });
  assert.equal(r.classes.has("dark"), false);
  assert.deepEqual(s.items, { theme: "light" });
  setTheme(true, { root: r, storage: s, store: undefined });
  assert.equal(r.classes.has("dark"), true);
  assert.deepEqual(s.items, { theme: "dark" });
});
