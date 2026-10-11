// [unit] logo_gallery: the logo gallery's Context control drives the hub theme
// (task brand-gallery-palette-and-theme). The rules read a theme and a choice and
// answer what to show, whether to flip the theme and whether to load the page.
import { test } from "node:test";
import assert from "node:assert/strict";

import { contextShown, choice, setTheme, fetchSvg, copySvg } from "../../app/javascript/logo_gallery.js";

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

// Copy SVG fetches on click (task logo-gallery-polish-pass, item 10).
const SVG = '<svg xmlns="http://www.w3.org/2000/svg"/>';

function answer(status = 200, type = "image/svg+xml", body = SVG) {
  return () => Promise.resolve({ ok: status >= 200 && status < 300, status, headers: { get: () => type }, text: () => Promise.resolve(body) });
}

class FakeItem {
  constructor(items) { this.items = items; }
}

test("fetchSvg answers a 2xx SVG's text, and refuses an error or a page in its place", async () => {
  assert.equal(await fetchSvg("/logos/turf/navbar", answer()), SVG);
  await assert.rejects(fetchSvg("/logos/turf/navbar", answer(404)));
  await assert.rejects(fetchSvg("/logos/turf/navbar", answer(200, "text/html; charset=utf-8", "<html>")), /no SVG/);
});

test("copySvg writes at once, inside the click, with a promise of the fetched text where ClipboardItem is there", async () => {
  const calls = [];
  const clipboard = {
    write: (items) => { calls.push("write"); return items[0].items["text/plain"].then((blob) => blob.text()).then((text) => { calls.push(text); }); },
    writeText: () => { calls.push("writeText"); return Promise.resolve(); },
  };
  const pending = copySvg("/logos/turf/navbar", { clipboard, fetchFn: answer(), ClipboardItemCtor: FakeItem });
  assert.deepEqual(calls, ["write"], "the write starts before anything is awaited");
  assert.equal(await pending, true);
  assert.deepEqual(calls, ["write", SVG]);
});

test("copySvg falls back to fetch, then writeText, without ClipboardItem or when the write is refused", async () => {
  const written = [];
  const clipboard = { writeText: (text) => { written.push(text); return Promise.resolve(); } };
  assert.equal(await copySvg("/u", { clipboard, fetchFn: answer() }), true);
  const refusing = { ...clipboard, write: () => Promise.reject(new Error("NotAllowedError")) };
  assert.equal(await copySvg("/u", { clipboard: refusing, fetchFn: answer(), ClipboardItemCtor: FakeItem }), true);
  assert.deepEqual(written, [SVG, SVG]);
});

test("copySvg rejects when the SVG cannot be fetched, or no clipboard takes it", async () => {
  const clipboard = { writeText: () => Promise.resolve() };
  await assert.rejects(copySvg("/u", { clipboard, fetchFn: answer(500) }));
  await assert.rejects(copySvg("/u", { clipboard: undefined, fetchFn: answer(), copyText: () => false }));
  assert.equal(await copySvg("/u", { clipboard: undefined, fetchFn: answer(), copyText: () => true }), true);
});
